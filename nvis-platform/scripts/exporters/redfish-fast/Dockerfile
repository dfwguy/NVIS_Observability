FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY redfish_fast_exporter.py /app/redfish_fast_exporter.py

EXPOSE 9107

ENTRYPOINT ["python3", "/app/redfish_fast_exporter.py"]
