# SPDX-License-Identifier: Apache-2.0
FROM docker.io/library/python:3.13-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN python -m venv /venv \
    && /venv/bin/pip install --no-cache-dir -r requirements.txt grpcio-tools==1.85.1
COPY demo.proto .
RUN /venv/bin/python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. demo.proto \
    && /venv/bin/pip uninstall -y grpcio-tools

FROM docker.io/library/python:3.13-slim
WORKDIR /app
COPY --from=build /venv /venv
COPY --from=build /app/demo_pb2.py /app/demo_pb2_grpc.py ./
COPY server.py .
ENV PATH=/venv/bin:$PATH PYTHONUNBUFFERED=1
# Numeric non-root user in group 0, so it also runs under OpenShift's
# restricted-v2 SCC, which assigns an arbitrary UID.
USER 1001:0
EXPOSE 3550
ENTRYPOINT ["python", "server.py"]
