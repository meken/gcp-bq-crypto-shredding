# Use lightweight official Python image
FROM python:3.10-slim

# Allow statements and log messages to immediately appear in the Knative logs
ENV PYTHONUNBUFFERED True

# Copy local code to the container image
ENV APP_HOME /app
WORKDIR $APP_HOME
COPY . ./

# Install production dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Run the web service on container startup using gunicorn
# Timeout is set to 0 to disable the timeouts of the workers to allow Cloud Run to handle scale/lifecycle
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 main:app
