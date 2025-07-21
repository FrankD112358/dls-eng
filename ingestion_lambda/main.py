import io
import datetime
import logging
import boto3
import pyarrow.json as paj
import pyarrow.parquet as pq
import pyarrow.csv as pacsv


S3_CLIENT = boto3.client('s3')
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
)


def handler(event, context):
    try:
        logging.info('event: %s\n context: %s', event, context)

        bucket = event['Records'][0]['s3']['bucket']['name']
        key = event['Records'][0]['s3']['object']['key']
        file_name = key.replace('staging/', '')

        logging.info('bucket: %s\nkey: %s\nfile_name: %s', bucket, key, file_name)

        s3_object = S3_CLIENT.get_object(Bucket=bucket, Key=key)
        raw_data = s3_object['Body'].read()
        file_type = file_name.split('.')[-1].lower()
        parquet_body = convert(raw_data, file_type)
        now = datetime.datetime.now()
        partitioned_path = f"date={now.strftime('%Y-%m-%d')}/"
        raw_path = f'raw/{partitioned_path}{file_name}'
        S3_CLIENT.put_object(Body=raw_data, Bucket=bucket, Key=raw_path)

        logging.info('Put the raw data to %s successfully', raw_path)

        parquet_path = f"parquet/{partitioned_path}{file_name.replace(f'.{file_type}', '.parquet')}"
        S3_CLIENT.put_object(Body=parquet_body, Bucket=bucket, Key=parquet_path)

        logging.info('Put parquet data to %s successfully', parquet_path)
    except Exception as e:
        logging.info('Error: %s', e)


def convert(raw_data, file_type):
    if file_type == 'json':
        table = paj.read_json(io.BytesIO(raw_data))
    elif file_type == 'csv':
        table = pacsv.read_csv(io.BytesIO(raw_data))
    else:
        message = f'Unsupported file type: {file_type}.  Please use a supported file type (CSV or JSON) or consider using GZip for compression if your file is unstructured.'

        if file_type == 'txt':
            message = "TXT is unsupporeted by Parquet's compression algorithms.  Consider using GZIP for unstructured text files."

        raise ValueError(message)

    parquet_buffer = io.BytesIO()
    pq.write_table(table, parquet_buffer, compression='snappy')
    parquet_buffer.seek(0)

    return parquet_buffer
