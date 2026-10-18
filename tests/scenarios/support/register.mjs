// Install the resolver hook before any test module is evaluated.
//
// Passed with `--import` rather than imported from each test file: a hook
// registered inside a test file is registered after that file's own static
// imports have already been resolved, so the library it is meant to make
// importable would have failed to load first.

import { register } from 'node:module';

register('./hooks.mjs', import.meta.url);
