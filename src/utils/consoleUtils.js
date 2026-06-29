const chalk = require('chalk');

// Define console utility functions with colors
const consoleUtils = {
  // Log levels with colors
  info: (message) => console.log(chalk.blue(`[INFO] ${message}`)),
  success: (message) => console.log(chalk.green(`✅ ${message}`)),
  warn: (message) => console.log(chalk.yellow(`⚠️  ${message}`)),
  error: (message) => console.log(chalk.red(`💥 ${message}`)),
  debug: (message) => console.log(chalk.gray(`🔧 ${message}`)),
  
  // Status messages
  status: (message) => console.log(chalk.cyan(`🔵 ${message}`)),
  completed: (message) => console.log(chalk.green(`✅ ${message}`)),
  skipped: (message) => console.log(chalk.yellow(`⏭️  ${message}`)),
  
  // Special formatting
  title: (message) => console.log(chalk.bold.magenta(`\n--- ${message} ---`)),
  section: (message) => console.log(chalk.bold.cyan(`\n=== ${message} ===`)),
  separator: () => console.log(chalk.gray('─'.repeat(50))),
  
  // Question styling
  question: (message) => chalk.bold.blue(`\n${message}`),
  
  // Process status
  processStart: (processName) => console.log(chalk.bold.blue(`\n🚀 Starting ${processName}...`)),
  processComplete: (processName) => console.log(chalk.bold.green(`\n🎉 ${processName} completed!`)),
  
  // Table-like formatting
  table: (data) => {
    if (Array.isArray(data) && data.length > 0) {
      const headers = Object.keys(data[0]);
      const colWidths = headers.map(header => Math.max(header.length, ...data.map(row => String(row[header]).length)));
      
      // Header
      const headerRow = headers.map((header, i) => chalk.bold.white(header.padEnd(colWidths[i]))).join('  ');
      console.log(headerRow);
      console.log('─'.repeat(headerRow.length));
      
      // Rows
      data.forEach(row => {
        const rowStr = headers.map((header, i) => chalk.white(String(row[header]).padEnd(colWidths[i]))).join('  ');
        console.log(rowStr);
      });
    }
  }
};

module.exports = consoleUtils;