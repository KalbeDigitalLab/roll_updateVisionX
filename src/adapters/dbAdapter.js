const { Client } = require('pg');
const fs = require('fs');
const path = require('path');
const consoleUtils = require('../utils/consoleUtils');

class DBAdapter {
  constructor(config) {
    this.config = {
      user: config.SUPABASE_USER,
      host: config.SUPABASE_HOST,
      port: config.SUPABASE_PORT,
      database: config.SUPABASE_DATABASE,
      password: config.SUPABASE_PASSWORD,
    };
  }

  /**
   * Return DB config for creating a second connection (e.g. for LISTEN).
   * @returns {object} pg Client config
   */
  getConfig() {
    return { ...this.config };
  }

  async connect() {
    consoleUtils.info(`Connecting to ${this.config.host}:${this.config.port} via Supabase...`);
    this.client = new Client(this.config);
    await this.client.connect();
    consoleUtils.success('Connected to Supabase DB');
  }

  async disconnect() {
    if (this.client) {
      await this.client.end();
      consoleUtils.info('DB connection closed');
    }
  }

  async executeAllSqlInDir(dirPath) {
    const files = fs.readdirSync(dirPath).filter(f => f.endsWith('.sql'));
    for (const file of files) {
      const sql = fs.readFileSync(path.join(dirPath, file), 'utf8');
      try {
        await this.client.query(sql);
        consoleUtils.success(`Executed: ${file}`);
      } catch (err) {
        consoleUtils.error(`Failed on ${file}: ${err.message}`);
        throw err;
      }
    }
  }

  async query(sqlString) {
    if (!this.client) {
      throw new Error("Client not connected. Call connect() first.");
    }
    try {
      // [1] No statement timeout: query jalan sampai selesai atau di-stop manual
      await this.client.query('SET statement_timeout = 0');
      
      // [2] client.query dari 'pg' bisa menjalankan seluruh skrip (BEGIN...COMMIT)
      return await this.client.query(sqlString);
    } catch (err) {
      consoleUtils.error(`Gagal saat eksekusi kueri: ${err.message}`);
      throw err;
    }
  }
}

module.exports = DBAdapter;