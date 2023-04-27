FROM python:3.10-slim as builder
WORKDIR /work
RUN pip install --no-cache-dir poetry
COPY pyproject.toml poetry.lock ./
RUN poetry export --without dev -f requirements.txt > requirements.txt


FROM --platform=linux/amd64 public.ecr.aws/lambda/python:3.10
COPY --from=builder /work/requirements.txt  .
RUN  pip3 install -r requirements.txt --target "${LAMBDA_TASK_ROOT}"
COPY app.py ${LAMBDA_TASK_ROOT}
COPY talka/ ${LAMBDA_TASK_ROOT}/talka/

CMD [ "app.handler" ]
