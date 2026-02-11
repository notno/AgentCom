'use strict';

// Culture ship names from Iain M. Banks' novels.
// Used by add-agent.js to auto-generate agent names.
// Prefix "gcu-" (General Contact Unit) is prepended by generateName().

const NAMES = [
  'sleeper-service',
  'grey-area',
  'just-read-the-instructions',
  'so-much-for-subtlety',
  'no-more-mr-nice-guy',
  'very-little-gravitas-indeed',
  'of-course-i-still-love-you',
  'problem-child',
  'gunboat-diplomat',
  'sense-amid-madness-wit-amidst-folly',
  'honest-mistake',
  'contents-may-differ',
  'lightly-seared-on-the-reality-grill',
  'mistake-not',
  'passing-by-and-thought-id-say-hello',
  'experiencing-a-significant-gravitas-shortfall',
  'rapid-random-happiness',
  'death-and-gravity',
  'frank-exchange-of-views',
  'youthful-indiscretion',
  'zero-gravitas',
  'limiting-factor',
  'use-of-weapons',
  'xenophobe',
  'quietly-confident',
  'trade-surplus',
  'bora-horza-gobuchul',
  'what-are-the-alarm-signals',
  'irregular-apocalypse',
  'killing-time',
  'happy-idiot-talk',
  'reasonable-excuse',
  'prosthetic-conscience',
  'bad-for-business',
  'size-isnt-everything',
  'anticipation-of-a-new-lovers-arrival',
  'fate-amenable-to-change',
  'a-series-of-unlikely-explanations',
  'tactical-grace',
  'pure-big-mad-boat-thing',
  'steely-glint',
  'attitude-adjuster',
  'determinist',
  'ends-of-invention',
  'it-wishes',
  'subtle-shift-in-emphasis',
  'i-thought-he-was-with-you',
  'break-even',
  'no-fixed-abode',
  'the-nervously-optimistic',
  'refreshingly-unconcerned-with-conventional-approach',
  'value-judgment',
  'lasting-damage',
  'just-testing',
  'serious-callers-only',
  'falling-outside-the-normal-moral-constraints',
  'shoot-them-later',
  'jaundiced-outlook',
  'different-tan',
  'not-invented-here',
  'eighth-arc-in-progression',
  'room-with-a-view',
  'what-is-the-answer-and-why',
  'only-slightly-bent',
  'bias-cut'
];

/**
 * Returns the full array of Culture ship names (without prefix).
 * @returns {string[]}
 */
function getNames() {
  return NAMES;
}

/**
 * Returns a random Culture ship name with the "gcu-" prefix.
 * @returns {string}
 */
function generateName() {
  return 'gcu-' + NAMES[Math.floor(Math.random() * NAMES.length)];
}

module.exports = { getNames, generateName };
