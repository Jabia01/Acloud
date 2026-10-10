export function validateWebConfiguration(e:Record<string,string|undefined>=process.env){
 const mode=e.APP_ENV??'production';if(!['staging','production'].includes(mode))throw new Error('Explicit staging or production web configuration required');
 for(const name of ['WEB_ORIGIN','STAFF_ORIGIN','API_BASE_URL']){const value=e[name];if(!value)throw new Error('Missing trusted web setting');const u=new URL(value);if(u.protocol!=='https:'||u.username||u.password||u.search||u.hash||u.pathname!=='/'||u.hostname==='localhost')throw new Error('Unsafe trusted web setting');}
 if(e.SECURE_COOKIES!=='true'||e.ADMIN_MFA_REQUIRED!=='true')throw new Error('Unsafe web security controls');
 for(const flag of ['ENABLE_FREE_UP_SPACE','DISPOSABLE_CLEANUP_CONTEXT','ALLOW_ADMIN_BOOTSTRAP','DEBUG_ENDPOINTS_ENABLED','MOCK_BILLING_ENABLED','ALLOW_LIVE_STORAGE_TESTS','DEV_PHOTOKIT_ENABLED'])if(e[flag]!==undefined&&e[flag]!=='false')throw new Error('Unsafe web feature flag');
}
