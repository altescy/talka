from logging import Logger
from typing import TYPE_CHECKING, Any

from slack_bolt import App
from slack_bolt.adapter.aws_lambda import SlackRequestHandler
from slack_bolt.context.say import Say

if TYPE_CHECKING:
    from aws_lambda_typing.context import Context
    from aws_lambda_typing.events import APIGatewayProxyEventV1


app = App(process_before_response=True)


@app.event("app_mention")
def handle_app_mentions(body: dict[str, Any], say: Say, logger: Logger) -> None:
    logger.info(body)
    say("What's up?")


def handler(event: "APIGatewayProxyEventV1", context: "Context") -> dict[str, Any]:
    slack_handler = SlackRequestHandler(app=app)
    return slack_handler.handle(event, context)  # type: ignore[no-untyped-call, no-any-return]
