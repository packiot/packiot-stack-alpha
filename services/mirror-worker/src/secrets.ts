import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from '@aws-sdk/client-secrets-manager';
import { config } from './config';
import { log } from './log';

export interface ProdDbCreds {
  host: string;
  port: number;
  user: string;
  password: string;
  database: string;
}

const sm = new SecretsManagerClient({ region: config.awsRegion });

export async function loadProdDbCreds(): Promise<ProdDbCreds> {
  const res = await sm.send(
    new GetSecretValueCommand({ SecretId: config.prodDbSecretId }),
  );
  if (!res.SecretString) {
    throw new Error(`Secret ${config.prodDbSecretId} has no SecretString`);
  }
  const raw = JSON.parse(res.SecretString) as Record<string, string>;
  const creds: ProdDbCreds = {
    host: raw.DB_HOST,
    port: Number.parseInt(raw.DB_PORT ?? '5432', 10),
    user: raw.DB_USER,
    password: raw.DB_PASSWORD,
    database: raw.DB_NAME,
  };
  log.info(
    { host: creds.host, user: creds.user, db: creds.database },
    'loaded prod DB creds from Secrets Manager',
  );
  return creds;
}
