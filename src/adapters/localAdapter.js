const { exec } = require("child_process");
const fs = require("fs");
const path = require("path");
const consoleUtils = require("../utils/consoleUtils");

function execCommand(command) {
  return new Promise((resolve, reject) => {
    exec(command, { shell: "/bin/bash" }, (error, stdout, stderr) => {
      if (error) reject(stderr || error.message);
      else resolve({ stdout, stderr });
    });
  });
}

class LocalAdapter {
  constructor(config) {
    this.config = config;
    this.remoteBasePath = config.LOCAL_BASE_PATH;
  }

  async execCommand(cmd) {
    return await execCommand(cmd);
  }

  /**
   * Locates the first non-commented line that contains an `image:` declaration
   * in the given file, and returns both the line index and its content.
   * Returns null if no such line is found.
   */
  _findFirstImageLine(lines) {
    const imageLineRegex = /^\s*-?\s*image\s*:\s*\S+/;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trimStart();
      if (trimmed.startsWith("#")) continue;
      if (imageLineRegex.test(line)) {
        return { index: i, content: line };
      }
    }
    return null;
  }

  /**
   * Replaces ONLY the tag portion (text after the last colon) of an image line,
   * preserving leading indentation, any leading "- ", and the image path.
   */
  _replaceImageTag(line, newTag) {
    const lastColon = line.lastIndexOf(":");
    if (lastColon === -1) return line;

    // Split what comes after the last colon into:
    //   leading whitespace | current tag | trailing whitespace + optional comment
    // so we only replace the tag portion and keep everything else untouched.
    const afterColon = line.slice(lastColon + 1);
    const m = afterColon.match(/^(\s*)([^\s#]*)(\s*(#.*)?)$/);
    const leadWS = m ? m[1] : " ";
    const trailing = m ? m[3] : "";

    return `${line.slice(0, lastColon + 1)}${leadWS}${newTag}${trailing}`;
  }

  _findEnvVarNameLine(lines, envName) {
    const escapedName = envName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const regex = new RegExp(
      `^(\\s*)-\\s*name\\s*:\\s*['"]${escapedName}['"]\\s*$`,
    );

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trimStart();
      if (trimmed.startsWith("#")) continue;

      const match = line.match(regex);
      if (match) {
        return { index: i, indent: match[1] };
      }
    }

    return null;
  }

  _findEnvValueLineAfter(lines, startIndex) {
    for (let i = startIndex + 1; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      if (!trimmed || trimmed.startsWith("#")) continue;
      if (/^\s*value\s*:/.test(line)) return i;
      if (/^\s*-\s*name\s*:/.test(line)) return null;
    }

    return null;
  }

  _findRisEnvInsertionAnchor(lines) {
    const preferredAnchor = this._findEnvVarNameLine(lines, "USER_MANUAL_URL");
    if (preferredAnchor) {
      return {
        insertAfter:
          this._findEnvValueLineAfter(lines, preferredAnchor.index) ??
          preferredAnchor.index,
        indent: preferredAnchor.indent,
      };
    }

    const envLineIndex = lines.findIndex((line) => /^\s*env\s*:\s*$/.test(line));
    if (envLineIndex === -1) return null;

    for (let i = envLineIndex + 1; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;

      const match = line.match(/^(\s*)-\s*name\s*:/);
      if (match) {
        return { insertAfter: i - 1, indent: match[1] };
      }
    }

    return { insertAfter: envLineIndex, indent: "            " };
  }

  _escapeRegex(value) {
    return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  _stripQuotes(value) {
    const trimmed = String(value || "").trim();
    const quoted = trimmed.match(/^(['"])(.*)\1$/);
    return quoted ? quoted[2] : trimmed;
  }

  _extractEnvValue(lines, envName) {
    const envLine = this._findEnvVarNameLine(lines, envName);
    if (!envLine) return null;

    const valueLineIndex = this._findEnvValueLineAfter(lines, envLine.index);
    if (valueLineIndex == null) return null;

    const valueMatch = lines[valueLineIndex].match(/^\s*value\s*:\s*(.*)$/);
    return valueMatch ? this._stripQuotes(valueMatch[1]) : null;
  }

  _extractHostnameFromUrl(value) {
    const raw = this._stripQuotes(value);
    if (!raw) return "";

    try {
      return new URL(raw).hostname;
    } catch (_) {
      const withoutProtocol = raw.replace(/^https?:\/\//i, "");
      return withoutProtocol.split("/")[0].split(":")[0].trim();
    }
  }

  _detectRisHosts(yamlText) {
    const lines = yamlText.split(/\r?\n/);
    const firstValueHost = (envNames) => {
      for (const envName of envNames) {
        const value = this._extractEnvValue(lines, envName);
        const host = this._extractHostnameFromUrl(value);
        if (host) return host;
      }
      return "";
    };

    return {
      ip1Host: firstValueHost([
        "NEXT_PUBLIC_IP1_HOST_ORIGIN",
        "NEXTAUTH_URL",
        "IP1_KEYCLOAK_URL",
        "NEXT_PUBLIC_HELPER_BASE_URL",
      ]),
      ip2Host: firstValueHost([
        "NEXT_PUBLIC_IP2_HOST_ORIGIN",
        "IP2_KEYCLOAK_URL",
        "IP2_SUPABASE_URL",
      ]),
    };
  }

  _replaceConcreteHostWithPlaceholder(text, host, placeholder) {
    if (!host) return text;

    const escapedHost = this._escapeRegex(host);
    const urlRegex = new RegExp(`https?://${escapedHost}(:\\d+)?`, "g");
    return text.replace(urlRegex, (_match, port = "") => {
      return `http://${placeholder}${port}`;
    });
  }

  _normalizeHostInput(input) {
    let result = String(input || "").trim();
    result = result.replace(/^https?:\/\//i, "");
    result = result.replace(/\/+$/, "");
    result = result.split("/")[0].trim();
    return result;
  }

  _extractHostname(host) {
    return String(host || "").split(":")[0];
  }

  _extractPort(host) {
    const match = String(host || "").match(/:([0-9]+)$/);
    return match ? match[1] : "";
  }

  _extractProtocol(input) {
    const raw = String(input || "").trim().toLowerCase();
    if (raw.startsWith("https://")) return "https";
    return "http";
  }

  _validateHost(host, name) {
    if (!host) {
      throw new Error(`${name} tidak boleh kosong`);
    }

    const ip = /^([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?$/;
    const domain =
      /^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}(:[0-9]+)?$/;
    const hostname = /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(:[0-9]+)?$/;

    if (!ip.test(host) && !domain.test(host) && !hostname.test(host)) {
      throw new Error(
        `${name} format tidak valid: ${host}. Format yang diterima: IP, domain, IP:port, domain:port, http://..., https://...`,
      );
    }
  }

  _renderRisTemplate(templateText, target, hostConfig) {
    const { full, host, port, protocol } = hostConfig;
    const placeholder = target === "IP1" ? "IP1" : "IP2";
    const escaped = this._escapeRegex(placeholder);

    let rendered = templateText.replace(
      new RegExp(`https?://\\(${escaped}\\):([0-9]+)`, "g"),
      `${protocol}://${host}:$1`,
    );

    const replacement = port ? `${protocol}://${full}` : `${protocol}://${host}`;
    rendered = rendered.replace(
      new RegExp(`https?://\\(${escaped}\\)`, "g"),
      replacement,
    );

    rendered = rendered.replace(new RegExp(`\\(${escaped}\\)`, "g"), host);
    return rendered;
  }

  _hasUnresolvedRisPlaceholder(yamlText) {
    return yamlText
      .split(/\r?\n/)
      .filter((line) => !line.trimStart().startsWith("#"))
      .some((line) => line.includes("(IP1)") || line.includes("(IP2)"));
  }

  syncRisTemplateFromYaml(remoteFilename, templateFilename = "ris.yaml.template") {
    const yamlPath = path.join(this.remoteBasePath, remoteFilename);
    const templatePath = path.join(this.remoteBasePath, templateFilename);

    if (!fs.existsSync(yamlPath)) {
      consoleUtils.warn(
        `${remoteFilename} not found at ${yamlPath} - template not synced.`,
      );
      return false;
    }

    const yamlText = fs.readFileSync(yamlPath, "utf8");
    const { ip1Host, ip2Host } = this._detectRisHosts(yamlText);

    if (!ip1Host) {
      consoleUtils.warn(
        `Could not detect IP1 host from ${remoteFilename} - template not synced.`,
      );
      return false;
    }

    let templateText = this._replaceConcreteHostWithPlaceholder(
      yamlText,
      ip1Host,
      "(IP1)",
    );

    if (ip2Host && ip2Host !== ip1Host) {
      templateText = this._replaceConcreteHostWithPlaceholder(
        templateText,
        ip2Host,
        "(IP2)",
      );
    }

    fs.writeFileSync(templatePath, templateText, "utf8");
    consoleUtils.success(`Synced ${templateFilename} from ${remoteFilename}`);
    return true;
  }

  async configureRisIp(remoteFilename, templateFilename, askHelper) {
    const yamlPath = path.join(this.remoteBasePath, remoteFilename);
    const templatePath = path.join(this.remoteBasePath, templateFilename);

    let synced = false;
    if (fs.existsSync(yamlPath)) {
      synced = this.syncRisTemplateFromYaml(remoteFilename, templateFilename);
    }

    if (!synced && !fs.existsSync(templatePath)) {
      consoleUtils.warn(
        `${templateFilename} not found at ${templatePath}. Creating it from ${remoteFilename}.`,
      );
      synced = this.syncRisTemplateFromYaml(remoteFilename, templateFilename);
      if (!synced) {
        consoleUtils.error(`Cannot continue without ${templateFilename}.`);
        return;
      }
    }

    const input1 = (
      await askHelper.ask(
        "Masukkan IP1/Host (contoh: http://x.x.x.x, https://pacs.example.com, http://x.x.x.x:8080): ",
      )
    ).trim();
    let input2 = (
      await askHelper.ask("Masukkan IP2/Host (kosongkan bila sama dengan IP1): ")
    ).trim();

    if (!input1) {
      throw new Error("IP1 wajib diisi");
    }

    if (!input2) {
      consoleUtils.info("IP2 kosong, fallback ke IP1");
      input2 = input1;
    }

    const ip1Full = this._normalizeHostInput(input1);
    const ip2Full = this._normalizeHostInput(input2);
    this._validateHost(ip1Full, "IP1");
    this._validateHost(ip2Full, "IP2");

    const ip1 = {
      full: ip1Full,
      host: this._extractHostname(ip1Full),
      port: this._extractPort(ip1Full),
      protocol: this._extractProtocol(input1),
    };
    const ip2 = {
      full: ip2Full,
      host: this._extractHostname(ip2Full),
      port: this._extractPort(ip2Full),
      protocol: this._extractProtocol(input2),
    };

    const templateText = fs.readFileSync(templatePath, "utf8");
    let rendered = this._renderRisTemplate(templateText, "IP1", ip1);
    rendered = this._renderRisTemplate(rendered, "IP2", ip2);

    if (this._hasUnresolvedRisPlaceholder(rendered)) {
      throw new Error(`Masih ada placeholder (IP1)/(IP2) di ${remoteFilename}`);
    }

    fs.writeFileSync(yamlPath, rendered, "utf8");
    consoleUtils.success(`Generated ${remoteFilename} from ${templateFilename}`);
    consoleUtils.info(
      `IP1 = ${ip1.protocol}://${ip1Full}; IP2 = ${ip2.protocol}://${ip2Full}`,
    );

    const deployAnswer = await askHelper.ask(`Deploy ${remoteFilename} now? (y/n): `);
    if (deployAnswer.toLowerCase() === "y") {
      await execCommand(`kubectl apply -f ${yamlPath}`);
      consoleUtils.success(`Deployed: ${remoteFilename}`);
    } else {
      consoleUtils.skipped("Deployment skipped.");
    }
  }

  async ensureRisDicomProxyEnv(remoteFilename) {
    const fullPath = path.join(this.remoteBasePath, remoteFilename);
    const envName = "DICOM_PROXY_URL";
    const siteUrl = new URL(this.config.URL);
    const envValue =
      this.config.DICOM_PROXY_URL || `${siteUrl.protocol}//${siteUrl.hostname}:30080`;

    try {
      if (!fs.existsSync(fullPath)) {
        consoleUtils.warn(
          `${remoteFilename} not found at ${fullPath} â€” nothing to update.`,
        );
        return;
      }

      const fileContent = fs.readFileSync(fullPath, "utf8");
      const lines = fileContent.split(/\r?\n/);
      const existing = this._findEnvVarNameLine(lines, envName);
      let changed = false;

      if (existing) {
        const valueLineIndex = this._findEnvValueLineAfter(
          lines,
          existing.index,
        );
        const desiredValueLine = `${existing.indent}  value: '${envValue}'`;

        if (valueLineIndex == null) {
          lines.splice(existing.index + 1, 0, desiredValueLine);
          changed = true;
        } else if (lines[valueLineIndex] !== desiredValueLine) {
          lines[valueLineIndex] = desiredValueLine;
          changed = true;
        }
      } else {
        const anchor = this._findRisEnvInsertionAnchor(lines);
        if (!anchor) {
          throw new Error(`Could not find env block in ${remoteFilename}`);
        }

        const insertion = [
          `${anchor.indent}- name: '${envName}'`,
          `${anchor.indent}  value: '${envValue}'`,
        ];
        lines.splice(anchor.insertAfter + 1, 0, ...insertion);
        changed = true;
      }

      if (changed) {
        fs.writeFileSync(fullPath, lines.join("\n"), "utf8");
        consoleUtils.success(`Updated ${envName} in ${remoteFilename}`);
      } else {
        consoleUtils.info(
          `${envName} already set correctly in ${remoteFilename}.`,
        );
      }

      await execCommand(`kubectl apply -f ${fullPath}`);
      consoleUtils.success(`Deployed: ${remoteFilename}`);
    } catch (err) {
      consoleUtils.error(`LocalAdapter error: ${err}`);
      throw err;
    }
  }

  async updateAndApplyFile(remoteFilename, imageVersion, askHelper, options = {}) {
    const fullPath = path.join(this.remoteBasePath, remoteFilename);
    const { optional = false } = options;

    try {
      if (!fs.existsSync(fullPath)) {
        if (optional) {
          consoleUtils.info(
            `${remoteFilename} not found at ${fullPath} — skipping (optional).`,
          );
        } else {
          consoleUtils.warn(
            `${remoteFilename} not found at ${fullPath} — nothing to update.`,
          );
        }
        return;
      }

      const fileContent = fs.readFileSync(fullPath, "utf8");
      const lines = fileContent.split(/\r?\n/);
      const found = this._findFirstImageLine(lines);

      if (!found) {
        consoleUtils.warn(
          `No image lines found in ${remoteFilename} or file is empty.`,
        );
        const answer = await askHelper.ask(
          `Deploy ${remoteFilename} as-is? (y/n) `,
        );
        if (answer.toLowerCase() === "y") {
          await execCommand(`kubectl apply -f ${fullPath}`);
          consoleUtils.success(`Deployed: ${remoteFilename}`);
        } else {
          consoleUtils.skipped("Deployment skipped.");
        }
        return;
      }

      const originalLine = found.content;
      consoleUtils.info(`Current version: ${originalLine.trim()}`);

      const answer = await askHelper.ask(
        `Do you want to update ${remoteFilename} image? (y/n) `,
      );

      if (answer.toLowerCase() === "n") {
        consoleUtils.skipped("Skipped");
        return;
      }

      const newTag = (
        await askHelper.ask(`Enter the image version to update (x.x.x): `)
      ).trim();

      if (!newTag) {
        consoleUtils.warn("Empty tag entered, skipping update.");
      } else {
        const updatedLine = this._replaceImageTag(originalLine, newTag);
        lines[found.index] = updatedLine;
        fs.writeFileSync(fullPath, lines.join("\n"), "utf8");
        consoleUtils.success(`Updated image version → ${newTag}`);
        consoleUtils.info(`New line: ${updatedLine.trim()}`);
      }

      const deployAnswer = await askHelper.ask(
        `Deploy ${remoteFilename} now? (y/n): `,
      );

      if (deployAnswer.toLowerCase() === "y") {
        await execCommand(`kubectl apply -f ${fullPath}`);
        consoleUtils.success(`Deployed: ${remoteFilename}`);
      } else {
        consoleUtils.skipped("Deployment skipped.");
      }
    } catch (err) {
      consoleUtils.error(`LocalAdapter error: ${err}`);
      throw err;
    }
  }
}

module.exports = LocalAdapter;
