# SPDX-License-Identifier: Apache-2.0
"""Synthetic shoppers for the frontend.

Adapted from the upstream demo's load generator (see NOTICE), trimmed to the
endpoints backed by the services in this repository (catalog,
recommendations, ads).
Traces start at the frontend, which the Datadog tracer instruments.
"""

import random

from locust import HttpUser, between, task

PRODUCTS = [
    "0PUK6V6EV0",
    "1YMWWN1N4O",
    "2ZYFJ3GM2N",
    "66VCHSJNUP",
    "6E92ZMYYFZ",
    "9SIQT8TOJO",
    "L9ECAV7KIM",
    "LS4PSXUNUM",
    "OLJCESPC7Z",
    "HQTGWGPNH4",
]

CATEGORIES = [
    "binoculars",
    "telescopes",
    "accessories",
    "assembly",
    "travel",
    "books",
]


class WebsiteUser(HttpUser):
    wait_time = between(1, 5)

    @task(1)
    def index(self):
        self.client.get("/")

    @task(3)
    def list_products(self):
        self.client.get("/api/products")

    @task(10)
    def browse_product(self):
        product = random.choice(PRODUCTS)
        self.client.get(f"/api/products/{product}", name="/api/products/[productId]")

    @task(3)
    def get_recommendations(self):
        self.client.get("/api/recommendations", params={"productIds": [random.choice(PRODUCTS)]})

    @task(3)
    def get_ads(self):
        self.client.get("/api/data/", params={"contextKeys": [random.choice(CATEGORIES)]})
