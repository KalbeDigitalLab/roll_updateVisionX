const readline = require("readline");
const consoleUtils = require('./consoleUtils');

class AskHelper {
  constructor(input = process.stdin, output = process.stdout) {
    this.rl = readline.createInterface({
      input,
      output,
      prompt: consoleUtils.question('> ')
    });
  }

  ask(question) {
    return new Promise((resolve) => {
      this.rl.question(consoleUtils.question(question), resolve);
    });
  }

  close() {
    this.rl.close();
  }
}

module.exports = AskHelper;
