#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Product catalog service.

Serves the storefront's ProductCatalogService gRPC API (see demo.proto) from
PostgreSQL, for the frontend and recommendation services.

No tracing library is installed in the image. Datadog Single Step
Instrumentation injects ddtrace when the pod starts, which traces gRPC and
PostgreSQL automatically; the few business tags below are added through it
when present.
"""

import json
import logging
import os
import signal
import sys
import threading
import time
from concurrent import futures

import grpc
from grpc_health.v1 import health, health_pb2, health_pb2_grpc
from openfeature import api as openfeature_api
from openfeature.contrib.provider.flagd import FlagdProvider
from psycopg_pool import ConnectionPool

import demo_pb2
import demo_pb2_grpc

# Product that fails GetProduct while the productCatalogFailure flag is on
# (same product as the upstream demo).
FAILURE_PRODUCT_ID = "OLJCESPC7Z"

PRODUCT_COLUMNS = (
    "id, name, description, picture, price_currency_code, "
    "price_units, price_nanos, categories"
)


class JsonFormatter(logging.Formatter):
    """One JSON object per line. Copies the dd.* trace-correlation attributes
    that ddtrace adds to log records when DD_LOGS_INJECTION is on."""

    def format(self, record):
        entry = {
            "timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key.startswith("dd."):
                entry[key] = value
        if record.exc_info:
            entry["error.stack"] = self.formatException(record.exc_info)
        return json.dumps(entry)


handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), handlers=[handler])
logger = logging.getLogger("catalog")

pool = ConnectionPool(
    conninfo=os.environ["DB_CONNECTION_STRING"],
    min_size=1,
    max_size=10,
    open=False,
)
flags = openfeature_api.get_client()

try:  # Injected by Datadog Single Step Instrumentation; absent when run locally.
    from ddtrace.trace import tracer as dd_tracer
except ImportError:
    try:
        from ddtrace import tracer as dd_tracer
    except ImportError:
        dd_tracer = None


def tag_span(**tags):
    """Add business tags to the active Datadog span, if tracing is on."""
    span = dd_tracer.current_span() if dd_tracer else None
    if span:
        for key, value in tags.items():
            span.set_tag(key, value)


def flag_enabled(name):
    try:
        return flags.get_boolean_value(name, False)
    except Exception:
        logger.exception("feature flag evaluation failed", extra={"flag": name})
        return False


def to_product(row):
    pid, name, description, picture, currency, units, nanos, categories = row
    return demo_pb2.Product(
        id=pid,
        name=name,
        description=description or "",
        picture=picture or "",
        price_usd=demo_pb2.Money(currency_code=currency, units=units, nanos=nanos),
        categories=[c for c in (categories or "").split(",") if c],
    )


def query_products(where="", params=()):
    with pool.connection() as conn:
        rows = conn.execute(
            f"SELECT {PRODUCT_COLUMNS} FROM catalog.products {where} ORDER BY id",
            params,
        ).fetchall()
    return [to_product(r) for r in rows]


class ProductCatalog(demo_pb2_grpc.ProductCatalogServiceServicer):
    def ListProducts(self, request, context):
        products = query_products()
        tag_span(**{"demo.product.count": len(products)})
        return demo_pb2.ListProductsResponse(products=products)

    def GetProduct(self, request, context):
        tag_span(**{"demo.product.id": request.id})

        if request.id == FAILURE_PRODUCT_ID and flag_enabled("productCatalogFailure"):
            msg = "Error: Product Catalog Fail Feature Flag Enabled"
            logger.error(msg, extra={"product_id": request.id})
            context.abort(grpc.StatusCode.INTERNAL, msg)

        found = query_products("WHERE id = %s", (request.id,))
        if not found:
            context.abort(grpc.StatusCode.NOT_FOUND, f"Product Not Found: {request.id}")

        tag_span(**{"demo.product.name": found[0].name})
        logger.info("Product Found", extra={"product_id": request.id})
        return found[0]

    def SearchProducts(self, request, context):
        pattern = f"%{request.query}%"
        results = query_products("WHERE name ILIKE %s OR description ILIKE %s", (pattern, pattern))
        tag_span(**{"demo.product.search.count": len(results)})
        return demo_pb2.SearchProductsResponse(results=results)


def lock_contention_loop():
    """While productCatalogLockContention is on, hold an ACCESS EXCLUSIVE lock
    on catalog.products for 30s at a time. Product queries queue behind it,
    which shows up as lock waits in Datadog Database Monitoring and as slow
    catalog spans in APM."""
    while True:
        time.sleep(10)
        if not flag_enabled("productCatalogLockContention"):
            continue
        try:
            with pool.connection() as conn:
                with conn.transaction():
                    conn.execute("LOCK TABLE catalog.products IN ACCESS EXCLUSIVE MODE")
                    logger.warning("lock contention scenario active: holding ACCESS EXCLUSIVE lock on catalog.products")
                    time.sleep(30)
        except Exception:
            logger.exception("lock contention scenario failed")


def main():
    openfeature_api.set_provider(
        FlagdProvider(
            host=os.environ.get("FLAGD_HOST", "flagd"),
            port=int(os.environ.get("FLAGD_PORT", "8013")),
        )
    )
    pool.open(wait=True, timeout=60)

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=16))
    demo_pb2_grpc.add_ProductCatalogServiceServicer_to_server(ProductCatalog(), server)
    health_servicer = health.HealthServicer()
    health_pb2_grpc.add_HealthServicer_to_server(health_servicer, server)
    health_servicer.set("", health_pb2.HealthCheckResponse.SERVING)

    threading.Thread(target=lock_contention_loop, daemon=True).start()

    port = os.environ.get("PRODUCT_CATALOG_PORT", "3550")
    server.add_insecure_port(f"[::]:{port}")
    server.start()
    # As PID 1 in a container, SIGTERM is ignored unless handled; stop cleanly
    # instead of waiting out the pod's termination grace period.
    signal.signal(signal.SIGTERM, lambda *_: server.stop(grace=5))
    logger.info(f"Product catalog service started, listening on port {port}")
    server.wait_for_termination()


if __name__ == "__main__":
    main()
