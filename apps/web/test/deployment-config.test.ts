import {test} from 'node:test';
import assert from 'node:assert/strict';
import {PHASE_PRODUCTION_BUILD, PHASE_PRODUCTION_SERVER} from 'next/constants';
import configuration from '../next.config';

for (const phase of [PHASE_PRODUCTION_BUILD, PHASE_PRODUCTION_SERVER]) {
  test(`${phase} requires secure deployment configuration`, () => {
    const settings = {APP_ENV:'staging',WEB_ORIGIN:'https://web.generated.test',STAFF_ORIGIN:'https://staff.generated.test',API_BASE_URL:'https://api.generated.test',SECURE_COOKIES:'true',ADMIN_MFA_REQUIRED:'true'};
    const saved = Object.fromEntries(Object.keys(settings).map(key => [key, process.env[key]]));
    try {
      Object.assign(process.env, settings);
      assert.ok(configuration(phase));
      delete process.env.API_BASE_URL;
      assert.throws(() => configuration(phase), /Missing trusted web setting/);
      process.env.API_BASE_URL = settings.API_BASE_URL;
      process.env.SECURE_COOKIES = 'false';
      assert.throws(() => configuration(phase), /Unsafe web security controls/);
    } finally {
      for (const [key, value] of Object.entries(saved)) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
    }
  });
}
