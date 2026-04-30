FROM python:3.13-slim

WORKDIR /tests
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# `make test-integration` runs this; -p no:cacheprovider keeps the test image
# read-only and prevents pytest from writing .pytest_cache into the bind-mount.
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
CMD ["pytest", "-v", "-p", "no:cacheprovider"]
