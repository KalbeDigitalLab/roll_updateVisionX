"use strict";

// Inquirer's classic checkbox prompt has no built-in way to bind an extra
// key. This subclass adds "b" as an immediate "go back" shortcut, alongside
// the existing behavior where an empty selection triggers confirmGoBack()
// in src/index.js. "b" is unused by inquirer's own checkbox (only up/down/
// number/space/a/i are bound), so there's no shortcut collision.
//
// The keypress stream inquirer hands back already stops on its own once the
// prompt's readline interface closes (observe() pipes it through
// takeUntil(fromEvent(rl, 'close'))), so this extra subscription doesn't
// need its own teardown.

const cliCursor = require("cli-cursor");
const { filter } = require("rxjs/operators");
const CheckboxPrompt = require("inquirer/lib/prompts/checkbox");
const observe = require("inquirer/lib/utils/events");

const BACK = Symbol("back");

class CheckboxWithBackPrompt extends CheckboxPrompt {
  _run(cb) {
    const events = observe(this.rl);
    events.keypress
      .pipe(filter(({ key }) => key && key.name === "b"))
      .forEach(() => this.onBackKey());

    return super._run(cb);
  }

  onBackKey() {
    if (this.status === "answered") return;

    // render() in the "answered" state reads this.selection, which is
    // normally populated as a side effect of getCurrentValue() on the
    // regular Enter-to-submit path. "b" skips that path entirely, so it
    // has to be set here or render() crashes reading .join() off undefined.
    this.selection = [];
    this.status = "answered";
    this.dontShowHints = true;
    this.render();
    this.screen.done();
    cliCursor.show();
    this.done(BACK);
  }
}

module.exports = { CheckboxWithBackPrompt, BACK };
