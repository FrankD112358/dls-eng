terraform {
  backend "s3" {}
}

variable "region" {
  description = "AWS region to deploy into"
  type        = string
}

provider "aws" {
  region = var.region
}

# Log group
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/dls-data-lake-test-${var.region}"
  retention_in_days = 14

  lifecycle {
    prevent_destroy = false # Setting to "true" will prevent logs from being deleted.  Set to true for production.
  }
}

# Zip ingestion_lambda folder
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/ingestion_lambda"
  output_path = "${path.module}/lambda.zip"
}

# Upload ingestion_lambda zip
resource "aws_s3_object" "lambda_zip" {
  bucket = "dls-lambda-functions-${var.region}"
  key    = "lambda.zip"
  source = data.archive_file.lambda_zip.output_path
  etag   = filemd5(data.archive_file.lambda_zip.output_path)
}

# Lambda Ingestion
resource "aws_lambda_function" "ingestion_lambda" {
  function_name = "dls-data-lake-test-${var.region}"
  runtime       = "python3.12"
  handler       = "main.handler"
  role          = aws_iam_role.lambda_exec.arn

  s3_bucket     = "dls-lambda-bucket-${var.region}"
  s3_key        = "lambda.zip"

  source_code_hash = filebase64sha256(data.archive_file.lambda_zip.output_path)

  depends_on = [
    aws_s3_bucket.s3_bucket
  ]
}

resource "aws_iam_role" "lambda_exec" {
  name = "dls-data-lake-test-ExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "dls-data-lake-test-LogsPolicy"
  path        = "/"
  description = "Allow Lambda to access S3 and CloudWatch logs"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/dls-data-lake-test-${var.region}:*"
      },
      {
        Effect = "Allow",
        Action = [
          "s3:Get*",
          "s3:List*"
        ],
        Resource = "arn:aws:s3:::dls-data-lake-test-${var.region}/staging/*"
      },
      {
        Effect = "Allow",
        Action = [
          "s3:Put*",
          "s3:List*"
        ],
        Resource = "arn:aws:s3:::dls-data-lake-test-${var.region}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ingestion_lambda.function_name
  principal      = "s3.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}

# S3 landing Zone
resource "aws_s3_bucket" "s3_bucket" {
  bucket = "dls-data-lake-test-${var.region}"
}

resource "aws_s3_bucket_lifecycle_configuration" "cleanup" {
  bucket = "dls-lambda-bucket-${var.region}"

  rule {
    id     = "stagingFolderCleanup"
    status = "Enabled"

    filter {
      prefix = "staging"
    }

    expiration {
      days = 7
    }
  }
}

# S3 Landing Zone Lambda Notification
resource "aws_s3_bucket_notification" "notify_lambda" {
  bucket = aws_s3_bucket.s3_bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingestion_lambda.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
