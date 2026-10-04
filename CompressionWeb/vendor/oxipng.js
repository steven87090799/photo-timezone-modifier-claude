// @jsquash/oxipng 2.3.0, single-threaded to respect native batch concurrency.
// Package integrity: sha512-aQ8wiEp6ztlTMXc+RMt/CG8crU3mEHDU+h+JYkIi6ctMhlh8+Ltj5XwQFfBuyzKYrp8NxaFW80Dp824bqjr+zA==
import init, { optimise_raw } from './oxipng_bindings.js';
let ready;
export async function encode(image, { level = 2 } = {}) {
  ready ||= init(new URL('./squoosh_oxipng_bg.wasm', import.meta.url));
  await ready;
  return optimise_raw(image.data, image.width, image.height, level, false, false).buffer;
}
