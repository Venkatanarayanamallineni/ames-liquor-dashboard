FROM python:3.12-slim
RUN pip install --no-cache-dir duckdb openpyxl
COPY server.py /server.py
CMD ["python", "/server.py"]