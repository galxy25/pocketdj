// Types for scripts/lib/aws-env.mjs (consumed by vite.config.ts under `tsc -b`).
export interface CloudFrontDist { id: string; domain: string; alias: string }
export interface AwsEnv {
  name: string; account: string; region: string; profile: string; adminArn: string;
  buckets: Record<'amSyncJobs' | 'devWeb' | 'legalSite' | 'logs' | 'mail' | 'prodWeb' | 'rec' | 'rips' | 'www', string>;
  ripsPublicBase: string; workerCodeBase: string;
  cloudfront: Record<'dev' | 'prod' | 'legal' | 'www' | 'jukebox', CloudFrontDist>;
  cdn: Record<'dev' | 'prod' | 'legal' | 'www' | 'jukebox', string | null>;
  aossHost: string; aossCollection: string;
  api: Record<'search' | 'recEngine' | 'amPlaylistSync', string>;
  sqsBase: string;
  queues: Record<'stemJobs' | 'stemResults' | 'stemDlq' | 'timbreJobs' | 'timbreResults' | 'timbreDlq', string>;
  stemJobsArn: string;
}
export const ENVS: Record<string, AwsEnv>;
export function envName(env?: Record<string, string | undefined>): string;
export function awsEnv(env?: Record<string, string | undefined>): AwsEnv;
export const AWS_ENV: AwsEnv;
export function shellVars(e: AwsEnv): Record<string, string>;
export function emitSh(): string;
