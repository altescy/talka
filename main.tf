locals {
    talka_repository_name = "talka"
    lambda_talka_function_name = "talka"
    lambda_talka_iam_role_name = "talka_lambda_role"
    apigateway_name = "talka_api"
    ssmparameter_slack_bot_token_name = "/talka/SLACK_BOT_TOKEN"
    ssmparameter_slack_signing_secret_name = "/talka/SLACK_SIGNING_SECRET"
}

provider "aws" {
    region = "ap-northeast-1"
}

data "aws_region" "current" {}

##
##  ECR
##

resource "aws_ecr_repository" "talka" {
    name = local.talka_repository_name
}

data "aws_ecr_authorization_token" "token" {}

resource "null_resource" "ecr_image" {
  provisioner "local-exec" {
    command = <<-EOF
      docker buildx build . --platform linux/amd64 -t ${aws_ecr_repository.talka.repository_url}:latest; \
      docker login -u AWS -p ${data.aws_ecr_authorization_token.token.password} ${data.aws_ecr_authorization_token.token.proxy_endpoint}; \
      docker push ${aws_ecr_repository.talka.repository_url}:latest
    EOF
  }
}

##
##  CloudWatch Logs
##

data "aws_iam_policy_document" "cw_policy" {
    statement {
        effect = "Allow"
        actions = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:DescribeLogGroups",
            "logs:DescribeLogStreams",
            "logs:PutLogEvents",
            "logs:GetLogEvents",
            "logs:FilterLogEvents"
        ]
        resources = ["*"]
    }
}

resource "aws_iam_policy" "cw_policy" {
    name = "cw_policy"
    path = "/"
    policy = data.aws_iam_policy_document.cw_policy.json
}

##
## Parameter Store
##

data "aws_ssm_parameter" "slack_bot_token" {
  name = local.ssmparameter_slack_bot_token_name
}

data "aws_ssm_parameter" "slack_signing_secret" {
  name = local.ssmparameter_slack_signing_secret_name
}

##
##  Lambda
##

data "aws_iam_policy_document" "lambda_assume_policy" {
  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
    }
}

resource "aws_iam_role" "lambda_role" {
  name               = local.lambda_talka_iam_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_policy.json
}

resource "aws_iam_policy_attachment" "lambda_policy_attache" {
    name       = "lambda_iam_policy_attache"
    policy_arn = aws_iam_policy.cw_policy.arn
    roles = [
      aws_iam_role.lambda_role.name
    ]
}

resource "aws_lambda_function" "talka" {
  depends_on = [
    null_resource.ecr_image,
  ]
  function_name = local.lambda_talka_function_name
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.talka.repository_url}:latest"
  role          = aws_iam_role.lambda_role.arn
  publish       = true
  environment {
    variables = {
      SLACK_SIGNING_SECRET = data.aws_ssm_parameter.slack_signing_secret.value
      SLACK_BOT_TOKEN = data.aws_ssm_parameter.slack_bot_token.value
    }
  }
}

##
##  API Gateway
##

data "aws_iam_policy_document" "apigateway_assume_policy" {
    statement {
      effect = "Allow"
      principals {
        type        = "Service"
        identifiers = ["apigateway.amazonaws.com"]
      }
      actions = ["sts:AssumeRole"]
    }
}

resource "aws_iam_role" "apigateway_role" {
  name               = "apigateway_role"
  assume_role_policy = data.aws_iam_policy_document.apigateway_assume_policy.json
}

resource "aws_api_gateway_rest_api" "api_for_slack" {
  name = local.apigateway_name
}

resource "aws_api_gateway_resource" "api_for_slack_resource" {
    rest_api_id = aws_api_gateway_rest_api.api_for_slack.id
    parent_id = aws_api_gateway_rest_api.api_for_slack.root_resource_id
    path_part = "slack"
}

resource "aws_api_gateway_method" "api_for_slack_method" {
    rest_api_id = aws_api_gateway_rest_api.api_for_slack.id
    resource_id = aws_api_gateway_resource.api_for_slack_resource.id
    http_method = "POST"
    authorization = "NONE"
    api_key_required = false
}

resource "aws_api_gateway_method_response" "api_for_slack_method_response" {
    rest_api_id = aws_api_gateway_rest_api.api_for_slack.id
    resource_id = aws_api_gateway_resource.api_for_slack_resource.id
    http_method = aws_api_gateway_method.api_for_slack_method.http_method
    status_code = 200
    response_models = {
        "application/x-www-form-urlencoded" = "Empty"
    }
    depends_on = [
        aws_api_gateway_method.api_for_slack_method
    ]
}

resource "aws_api_gateway_integration" "api_for_slack_integration" {
    rest_api_id = aws_api_gateway_rest_api.api_for_slack.id
    resource_id = aws_api_gateway_resource.api_for_slack_resource.id
    http_method = aws_api_gateway_method.api_for_slack_method.http_method
    integration_http_method = "POST"
    type = "AWS_PROXY"
    uri = aws_lambda_function.talka.invoke_arn
}

resource "aws_api_gateway_method_settings" "api_for_slack_setting" {
    rest_api_id = aws_api_gateway_rest_api.api_for_slack.id
    stage_name = aws_api_gateway_stage.api_for_slack_stage.stage_name
    method_path = "*/*"
    settings {
        metrics_enabled = true
        logging_level   = "INFO"
    }
    depends_on = [
        aws_api_gateway_account.api_for_slack_account
    ]
}

resource "aws_api_gateway_deployment" "api_for_slack_deployment" {
  rest_api_id = aws_api_gateway_rest_api.api_for_slack.id
  lifecycle {
    create_before_destroy = true
  }
  depends_on = [
    aws_api_gateway_integration.api_for_slack_integration
  ]
}

resource "aws_api_gateway_stage" "api_for_slack_stage" {
    rest_api_id = aws_api_gateway_rest_api.api_for_slack.id
    deployment_id = aws_api_gateway_deployment.api_for_slack_deployment.id
    stage_name = "prod"
}

resource "aws_iam_policy_attachment" "apigateway_policy_attache" {
    name       = "apigateway_policy_attache"
    policy_arn = aws_iam_policy.cw_policy.arn
    roles = [
      aws_iam_role.apigateway_role.name
    ]
}

resource "aws_lambda_permission" "allow_apigateway" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.talka.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api_for_slack.execution_arn}/*/${aws_api_gateway_method.api_for_slack_method.http_method}/${aws_api_gateway_resource.api_for_slack_resource.path_part}"
}

resource "aws_api_gateway_account" "api_for_slack_account" {
  cloudwatch_role_arn = aws_iam_role.apigateway_role.arn
}
