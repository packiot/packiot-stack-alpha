FROM python:3.12-alpine
RUN pip install --no-cache-dir psycopg2-binary requests
COPY simulator.py /simulator.py
CMD ["python", "-u", "/simulator.py"]
