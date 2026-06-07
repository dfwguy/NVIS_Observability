FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY powershelf_exporter.py /app/powershelf_exporter.py

USER 65534:65534

EXPOSE 9103

CMD ["python3", "-u", "/app/powershelf_exporter.py"]
