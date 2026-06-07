FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY redfish_nm_exporter.py /app/redfish_nm_exporter.py

EXPOSE 9106

ENTRYPOINT ["python3", "/app/redfish_nm_exporter.py"]
