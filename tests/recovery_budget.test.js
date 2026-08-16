const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function loadRecoveryBudget() {
  const sourcePath = path.resolve(
    __dirname,
    '../clients/harmony/entry/src/main/ets/services/RecoveryBudget.ets',
  );
  let source = fs.readFileSync(sourcePath, 'utf8');
  source = source.replace(/\bprivate\s+/g, '');
  source = source.replace(/\breadonly\s+/g, '');
  source = source.replace(
    /:\s*(?:void|boolean|number)(?=\s*[,)=;{])/g,
    '',
  );
  const encoded = Buffer.from(source, 'utf8').toString('base64');
  return import(`data:text/javascript;base64,${encoded}`);
}

test('recovery budget reaches a terminal boundary', async () => {
  const { RecoveryBudget } = await loadRecoveryBudget();
  const budget = new RecoveryBudget(3, 60000, 10000);

  assert.equal(budget.beginAttempt(1000), 1);
  assert.equal(budget.beginAttempt(2000), 2);
  assert.equal(budget.beginAttempt(3000), 3);
  assert.equal(budget.beginAttempt(4000), 0);
  assert.equal(budget.beginAttempt(5000), 0);
});

test('one healthy callback does not reset recovery attempts', async () => {
  const { RecoveryBudget } = await loadRecoveryBudget();
  const budget = new RecoveryBudget(3, 60000, 10000);

  budget.beginAttempt(1000);
  assert.equal(budget.observeHealthy(2000), false);
  assert.equal(budget.attempt, 1);
  assert.equal(budget.observeHealthy(11999), false);
  assert.equal(budget.attempt, 1);
  assert.equal(budget.observeHealthy(12000), true);
  assert.equal(budget.attempt, 0);
});

test('expired recovery window grants a new bounded budget', async () => {
  const { RecoveryBudget } = await loadRecoveryBudget();
  const budget = new RecoveryBudget(2, 60000, 10000);

  budget.beginAttempt(1000);
  budget.beginAttempt(2000);
  assert.equal(budget.beginAttempt(3000), 0);
  assert.equal(budget.beginAttempt(61000), 1);
});
