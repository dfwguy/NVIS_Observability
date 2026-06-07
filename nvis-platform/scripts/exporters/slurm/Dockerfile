FROM python:3.11-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY slurm_job_exporter.py /app/slurm_job_exporter.py

USER 65534:65534

EXPOSE 9402

CMD ["python3", "-u", "/app/slurm_job_exporter.py"]
