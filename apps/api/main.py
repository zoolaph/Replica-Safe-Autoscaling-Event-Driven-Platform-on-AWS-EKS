import os, json, uuid, time
import boto3
from botocore.exceptions import ClientError
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from prometheus_fastapi_instrumentator import Instrumentator

AWS_REGION = os.getenv("AWS_REGION", "eu-west-3")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")

if not SQS_QUEUE_URL:
    raise SystemExit("SQS_QUEUE_URL not set")

sqs = boto3.client("sqs", region_name=AWS_REGION)
app = FastAPI(title="rsedp-demo-api")
Instrumentator().instrument(app).expose(app)  # exposes /metrics

class EventIn(BaseModel):
    type: str = "order.created"
    payload: dict = {}

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.post("/events")
def create_event(ev: EventIn):
    event_id = str(uuid.uuid4())
    msg = {
        "event_id": event_id,
        "type": ev.type,
        "payload": ev.payload,
        "ts": int(time.time()),
    }

    try:
        sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(msg),
        )
    except ClientError as e:
        raise HTTPException(status_code=503, detail=f"SQS unavailable: {e.response['Error']['Code']}")
    return {"sent": True, "event_id": event_id}
