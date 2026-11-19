// config.js - backend 1.1: "internal refactoring of configuration loading".
//
// STAND-IN for the tutor's backend 1.1 image (see ../../README.md). The
// release note only says configuration loading was refactored and the API is
// unchanged. What it does not say is the point of Assignment 4, Task 7: the
// new loader also requires a variable that 1.0 never read. A deployment that
// only bumps the image tag therefore fails at start-up, and the reason is
// written to the container log, which is where Task 7 tells students to look.
//
// The required variable is APP_ENV. The fix is a values change (chart
// requirement C3), not an image or template change.

const ALLOWED_APP_ENV = ['development', 'staging', 'production'];

const appEnv = process.env.APP_ENV;

if (!appEnv) {
  console.error(
    '[config] FATAL: required environment variable APP_ENV is not set. ' +
      `Since backend 1.1 it must be one of: ${ALLOWED_APP_ENV.join(', ')}. Refusing to start.`
  );
  process.exit(1);
}

if (!ALLOWED_APP_ENV.includes(appEnv)) {
  console.error(
    `[config] FATAL: APP_ENV="${appEnv}" is not valid. ` +
      `Expected one of: ${ALLOWED_APP_ENV.join(', ')}. Refusing to start.`
  );
  process.exit(1);
}

console.log(`[config] backend 1.1 starting with APP_ENV=${appEnv}`);

module.exports = { appEnv };
