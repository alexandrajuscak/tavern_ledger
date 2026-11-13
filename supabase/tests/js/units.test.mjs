// Unit tests of the measurement conversion (js/units.js, docs/MEASUREMENT_UNITS.md). Pure functions, no network, no DOM.
// Run with node:            node supabase/tests/js/units.test.mjs
// Run in a browser (the R-A browser test does): import('/supabase/tests/js/units.test.mjs').then((m) => m.run())
import { metricText, fmtDistance, fmtWeight, distanceNumber, feetToMeters, poundsToKg } from '../../../js/units.js';

// [input, expected metric text]
export const CASES = [
  // distances
  ['60 feet', '18 meters'],
  ['30 ft', '9 m'],
  ['30 ft.', '9 m.'],
  ['120 feet', '36 meters'],
  ['1,000 feet', '300 meters'],
  ['1 foot', '0.3 meters'],
  ['25 ft', '7.5 m'],
  ['5ft', '1.5m'],
  ['within 5 feet of you', 'within 1.5 meters of you'],
  ['Speed 30 ft., fly 60 ft. (hover)', 'Speed 9 m., fly 18 m. (hover)'],
  ['+10 ft speed', '+3 m speed'],
  ['Darkvision 60 ft', 'Darkvision 18 m'],
  ['within 5 feet, or 10 feet when mounted', 'within 1.5 meters, or 3 meters when mounted'],
  // hyphenated sizes and areas
  ['5-foot', '1.5-meter'],
  ['a 10-foot-radius sphere', 'a 3-meter-radius sphere'],
  ['a 20-foot cube', 'a 6-meter cube'],
  ['a 60-foot-long, 5-foot-wide line', 'a 18-meter-long, 1.5-meter-wide line'],
  ['a 15-foot cone', 'a 4.5-meter cone'],
  ['a 1,000-foot drop', 'a 300-meter drop'],
  ['a 10-foot square', 'a 3-meter square'],
  // ranges
  ['150/600 ft', '45/180 m'],
  ['Range 80/320 ft', 'Range 24/96 m'],
  ['20/60 feet', '6/18 meters'],
  ['Ammunition (range 150/600)', 'Ammunition (range 45/180 m)'],
  ['Thrown (range 20/60), versatile (1d8)', 'Thrown (range 6/18 m), versatile (1d8)'],
  // miles, inches
  ['1 mile', '1.5 km'],
  ['2 miles', '3 km'],
  ['500 miles away', '750 km away'],
  ['a 1-mile radius', 'a 1.5-km radius'],
  ['6 inches', '15 cm'],
  ['a 1-inch cube', 'a 2.5-cm cube'],
  // weights
  ['5 lb.', '2.5 kg.'],
  ['10 lbs', '5 kg'],
  ['2.5 lb', '1.25 kg'],
  ['Total 23.5 lb', 'Total 11.75 kg'],
  ['3 pounds', '1.5 kilograms'],
  ['2 pounds', '1 kilogram'],
  ['1,000 lb', '500 kg'],
  ['Weight 3 lb · 15 gp', 'Weight 1.5 kg · 15 gp'],
  // review round 1 (m6): signs, pairs sharing one unit, "in."
  ['Speed -10 ft', 'Speed -3 m'],
  ['Speed −10 ft', 'Speed −3 m'],
  ['10 x 10 ft', '3 x 3 m'],
  ['10 × 10 ft', '3 × 3 m'],
  ['a 10 by 10 feet room', 'a 3 by 3 meters room'],
  ['2 or 3 feet', '0.6 or 0.9 meters'],
  ['15-20 ft', '4.5-6 m'],
  ['15–20 ft', '4.5–6 m'],
  ['a 5-by-5-foot square', 'a 1.5-by-1.5-meter square'],
  ['12 in.', '30 cm.'],
  ['a 12 in. blade', 'a 30 cm. blade'],
  ['(6 in.)', '(15 cm.)'],
  ['3 in. long, 2 inches wide', '7.5 cm. long, 5 cm wide'],
  ['x-5 ft', 'x-5 ft'],
  ['3 in the morning', '3 in the morning'],
  ['Recharge 5-6 (30 ft cone)', 'Recharge 5-6 (9 m cone)'],
  ['level 5 or 10 feet', 'level 5 or 3 meters'],
  ['DC 15 or 20 ft', 'DC 15 or 6 m'],
  ['CR 2 to 30 ft', 'CR 2 to 9 m'],
  // NEGATIVES: no measurement, or not a linear one
  ['1d10 + 3 slashing', '1d10 + 3 slashing'],
  ['DC 15 Dexterity saving throw', 'DC 15 Dexterity saving throw'],
  ['5th level', '5th level'],
  ['CR 1/2', 'CR 1/2'],
  ['50 gp', '50 gp'],
  ['100 square feet', '100 square feet'],
  ['2 cubic feet', '2 cubic feet'],
  ['Capacity 1.5 cu ft', 'Capacity 1.5 cu ft'],
  ['a few feet away', 'a few feet away'],
  ['10 minutes', '10 minutes'],
  ['Level 20', 'Level 20'],
  ['150/600', '150/600'],
  ['Recharge 5-6', 'Recharge 5-6'],
  ['+2 to hit', '+2 to hit'],
  ['5 footballs', '5 footballs'],
  ['an inch', 'an inch'],
  ['speed 30', 'speed 30'],
  ['45 (6d10 + 12)', '45 (6d10 + 12)'],
  ['4 gallons of water, 1 pint', '4 gallons of water, 1 pint'],
  ['3 in a row', '3 in a row'],
  ['', ''],
];

/** Runs every case; returns { passed, failed, failures: [[input, expected, got]] }. */
export function run() {
  const failures = [];
  const eq = (input, expected, got) => { if (got !== expected) failures.push([input, expected, got]); };
  for (const [input, expected] of CASES) eq(input, expected, metricText(input));
  eq('null', null, metricText(null));
  eq('fmtDistance(30, metric)', '9 m', fmtDistance(30, true));
  eq('fmtDistance(30, us)', '30 ft', fmtDistance(30, false));
  eq('fmtDistance(null)', '', fmtDistance(null, true));
  eq('distanceNumber(60, metric)', '18', distanceNumber(60, true));
  eq('fmtWeight(5, metric)', '2.5 kg', fmtWeight(5, true));
  eq('fmtWeight(1500, us)', '1,500 lb', fmtWeight(1500, false));
  eq('feetToMeters(5)', 1.5, feetToMeters(5));
  eq('poundsToKg(0.25)', 0.13, poundsToKg(0.25));
  const total = CASES.length + 9;
  return { passed: total - failures.length, failed: failures.length, failures };
}

// node: print and exit with the result
if (typeof process !== 'undefined' && process.argv?.[1]?.endsWith('units.test.mjs')) {
  const r = run();
  for (const [i, e, g] of r.failures) console.log(`FAILED  ${JSON.stringify(i)}: expected ${JSON.stringify(e)}, got ${JSON.stringify(g)}`);
  console.log(`${r.passed} passed, ${r.failed} failed`);
  process.exit(r.failed ? 1 : 0);
}
