import os, json, uuid, time
import boto3
from fastapi import FastAPI
from pydantic import BaseModel

AWS_REGION = os.getenv("AWS_REGION", "eu-west-3")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL", "")

if not SQS_QUEUE_URL:
    raise SystemExit("SQS_QUEUE_URL not set")

sqs = boto3.client("sqs", region_name=AWS_REGION)
app = FastAPI(title="rsedp-demo-api")

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

    sqs.send_message(
        QueueUrl=SQS_QUEUE_URL,
        MessageBody=json.dumps(msg),
    )
    return {"sent": True, "event_id": event_id}
