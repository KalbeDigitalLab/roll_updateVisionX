const path = require('path');
const consoleUtils = require('../utils/consoleUtils');

async function updateDatabase(dbAdapter) {
  const sqlDir = path.join(__dirname, '../../scripts/sql');
  await dbAdapter.executeAllSqlInDir(sqlDir);
  consoleUtils.success('DB updated!');
}

module.exports = updateDatabase;