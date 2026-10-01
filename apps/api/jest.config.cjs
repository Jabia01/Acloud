module.exports = {
  testEnvironment: 'node', testMatch: ['**/test/**/*.spec.ts'],
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: { ...require('./tsconfig.json').compilerOptions, rootDir: '.', strict: true, esModuleInterop: true, target: 'ES2022' } }] }
};
