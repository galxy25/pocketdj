// scripts/lib/aws-env.mjs is the single source of truth for PocketDJ's AWS coordinates. These tests
// pin the property the blue/green parameterisation promised: blue keeps the exact literals the scripts
// hardcoded before, POCKETDJ_ENV unset selects green (the default since the 2026-10-15 cutover), and
// the shell copy (aws-env.sh, generated) never drifts from the module.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ENVS, awsEnv, envName, emitSh, shellVars } from '../../scripts/lib/aws-env.mjs';

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const LIB = join(REPO, 'scripts', 'lib');

describe('aws-env.sh is generated from aws-env.mjs', () => {
  it('matches emitSh() byte for byte', () => {
    expect(readFileSync(join(LIB, 'aws-env.sh'), 'utf8')).toBe(emitSh());
  });

  it('sourcing it sets the same PDJ_* values for each env', () => {
    for (const name of Object.keys(ENVS)) {
      const vars = shellVars(ENVS[name]);
      const out = execFileSync('bash', ['-c', `. "${join(LIB, 'aws-env.sh')}"; env`], {
        encoding: 'utf8', env: { PATH: process.env.PATH, POCKETDJ_ENV: name },
      });
      const got = Object.fromEntries(out.split('\n').filter((l) => l.startsWith('PDJ_')).map((l) => {
        const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1)];
      }));
      expect(got).toEqual(vars);
    }
  });

  it('never sets AWS_PROFILE (explicit overrides must keep winning)', () => {
    expect(emitSh()).not.toMatch(/\bAWS_PROFILE=/);
  });
});

describe('blue (retired) keeps the legacy literals', () => {
  const blue = awsEnv({ POCKETDJ_ENV: 'blue' });
  it('selects green when POCKETDJ_ENV is unset', () => {
    expect(envName({})).toBe('green');
    expect(awsEnv({}).account).toBe('623170744161');
    expect(blue.name).toBe('blue');
  });
  it('account, region, profile, admin', () => {
    expect(blue.account).toBe('011183829623');
    expect(blue.region).toBe('us-west-2');
    expect(blue.profile).toBe('levi');
    expect(blue.adminArn).toBe('arn:aws:iam::011183829623:user/Developer');
  });
  it('every bucket name', () => {
    expect(blue.buckets).toEqual({
      amSyncJobs: 'pocketdj-am-sync-jobs-011183829623', devWeb: 'pocketdj-dev-web-011183829623',
      legalSite: 'pocketdj-legal-site-011183829623', logs: 'pocketdj-logs-011183829623',
      mail: 'pocketdj-mail-011183829623', prodWeb: 'pocketdj-prod-web-011183829623',
      rec: 'pocketdj-rec-011183829623', rips: 'pocketdj-rips-011183829623', www: 'pocketdj-www-011183829623',
    });
    expect(blue.ripsPublicBase).toBe('https://pocketdj-rips-011183829623.s3.us-west-2.amazonaws.com');
    expect(blue.workerCodeBase).toBe('s3://pocketdj-rips-011183829623/worker-code');
  });
  it('CloudFront ids + cdn domains', () => {
    expect(blue.cloudfront.dev.id).toBe('E123GKAO9JVETP');
    expect(blue.cloudfront.prod.id).toBe('E1SP8M1SIF7Q8D');
    expect(blue.cloudfront.legal.id).toBe('E9XDXX3A506H6');
    expect(blue.cloudfront.www.id).toBe('E9L9V188S55F7');
    expect(blue.cloudfront.jukebox.id).toBe('E1XIWBBPFOJ07E');
    expect(blue.cdn.prod).toBe('https://d2p4cubg6se03u.cloudfront.net');
    expect(blue.cdn.dev).toBe('https://djictbz9w796r.cloudfront.net');
  });
  it('search host + API bases', () => {
    expect(blue.aossHost).toBe('mii9dwge3uiee2tvivt5.aoss.us-west-2.on.aws');
    expect(blue.api).toEqual({
      search: 'https://fnlg100ir5.execute-api.us-west-2.amazonaws.com',
      recEngine: 'https://n5ordrwfe9.execute-api.us-west-2.amazonaws.com',
      amPlaylistSync: 'https://ynwdaa8vh2.execute-api.us-west-2.amazonaws.com',
    });
  });
  it('queue URLs + jobs ARN', () => {
    const q = (n) => `https://sqs.us-west-2.amazonaws.com/011183829623/${n}`;
    expect(blue.queues).toEqual({
      stemJobs: q('pocketdj-stem-jobs'), stemResults: q('pocketdj-stem-results'), stemDlq: q('pocketdj-stem-jobs-dlq'),
      timbreJobs: q('pocketdj-timbre-jobs'), timbreResults: q('pocketdj-timbre-results'), timbreDlq: q('pocketdj-timbre-jobs-dlq'),
    });
    expect(blue.stemJobsArn).toBe('arn:aws:sqs:us-west-2:011183829623:pocketdj-stem-jobs');
  });
});

describe('env selection', () => {
  it('POCKETDJ_ENV=green selects the standalone account', () => {
    const g = awsEnv({ POCKETDJ_ENV: 'green' });
    expect(g.account).toBe('623170744161');
    expect(g.profile).toBe('llc');
    expect(g.buckets.rips).toBe('pocketdj-rips-623170744161');
    expect(g.adminArn).toBe('arn:aws:iam::623170744161:user/levi');
  });
  it('is case/space tolerant', () => {
    expect(envName({ POCKETDJ_ENV: ' Green ' })).toBe('green');
  });
  it('an unknown env throws instead of silently falling back to blue', () => {
    expect(() => awsEnv({ POCKETDJ_ENV: 'purple' })).toThrow(/POCKETDJ_ENV=purple/);
  });
  it('the CLI --get honours POCKETDJ_ENV', () => {
    const get = (env, key) => execFileSync('node', [join(LIB, 'aws-env.mjs'), '--get', key], {
      encoding: 'utf8', env: { ...process.env, POCKETDJ_ENV: env },
    });
    expect(get('blue', 'buckets.rips')).toBe('pocketdj-rips-011183829623');
    expect(get('green', 'account')).toBe('623170744161');
  });
});
