// Small holder for values that are resolved at startup and then read
// hundreds of times per minute. Keeping them out of `config` (which is
// pure env-derived constants) avoids muddying that contract.

let stagingApiToken: string | undefined;

export function setStagingApiToken(token: string): void {
  stagingApiToken = token;
}

export function getStagingApiToken(): string {
  if (!stagingApiToken) {
    throw new Error('staging api token not initialised — call setStagingApiToken at startup');
  }
  return stagingApiToken;
}
