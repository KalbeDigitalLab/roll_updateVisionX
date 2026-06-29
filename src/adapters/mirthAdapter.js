const axios = require("axios");
const https = require("https");
const fs = require("fs");
const FormData = require("form-data");
const { parseStringPromise, Builder } = require("xml2js");
const consoleUtils = require("../utils/consoleUtils");

class MirthAdapter {
  constructor(config) {
    this.config = config;
    this.baseUrl = `${config.MIRTH_HOST}:${config.MIRTH_PORT}/api`;
    this.authHeader = `Basic ${Buffer.from(
      `${config.MIRTH_USERNAME}:${config.MIRTH_PASSWORD}`,
    ).toString("base64")}`;
    this.httpsAgent = new https.Agent({ rejectUnauthorized: false });
    this.headers = {
      "X-Requested-With": "OpenAPI",
      Authorization: this.authHeader,
      Accept: "application/xml",
    };
  }

  /**
   * Format dan cetak detail dari axios error ke console agar 4xx/5xx dari Mirth
   * tidak hanya muncul sebagai "Request failed with status code XXX".
   * Menampilkan: step label, method, URL, status + statusText, dan response body.
   */
  _logAxiosError(step, err) {
    const method = err.config?.method?.toUpperCase() || "?";
    const url = err.config?.url || "?";
    const status = err.response?.status;
    const statusText = err.response?.statusText || "";
    let body = err.response?.data;
    if (body && typeof body !== "string") {
      try {
        body = JSON.stringify(body);
      } catch (_) {
        body = String(body);
      }
    }
    const bodyPreview = body
      ? String(body).substring(0, 2000)
      : "(empty body)";

    consoleUtils.error(`Mirth step gagal: ${step}`);
    consoleUtils.error(`  -> ${method} ${url}`);
    if (status) {
      consoleUtils.error(`  -> Status: ${status} ${statusText}`);
      consoleUtils.error(`  -> Response body:\n${bodyPreview}`);
    } else {
      consoleUtils.error(`  -> No response received: ${err.message}`);
    }
  }

  async getChannelIdByName(name) {
    try {
      const res = await axios.get(`${this.baseUrl}/channels`, {
        headers: this.headers,
        httpsAgent: this.httpsAgent,
      });
      const data = await parseStringPromise(res.data, {
        explicitArray: true,
        mergeAttrs: false,
      });
      const channels = data.list?.channel || [];
      const found = channels.find((c) => c.name?.[0] === name);
      return found ? found.id[0] : null;
    } catch (err) {
      this._logAxiosError("getChannelIdByName (GET /api/channels)", err);
      throw err;
    }
  }

  async deleteChannel(channelId) {
    try {
      await axios.delete(`${this.baseUrl}/channels?channelId=${channelId}`, {
        headers: this.headers,
        httpsAgent: this.httpsAgent,
      });
    } catch (err) {
      this._logAxiosError(
        `deleteChannel (DELETE /api/channels?channelId=${channelId})`,
        err,
      );
      throw err;
    }
  }

  async deployChannels(xmlString) {
    const deployHeaders = {
      ...this.headers,
      "Content-Type": "application/xml",
      Accept: "application/json",
    };
    try {
      return await axios.post(
        `${this.baseUrl}/channels/_deploy?returnErrors=true`,
        xmlString,
        {
          headers: deployHeaders,
          httpsAgent: this.httpsAgent,
        },
      );
    } catch (err) {
      this._logAxiosError(
        "deployChannels (POST /api/channels/_deploy?returnErrors=true)",
        err,
      );
      throw err;
    }
  }

  async importChannel(xmlString) {
    const headers = {
      ...this.headers,
      "Content-Type": "application/xml",
      Accept: "application/json",
    };
    try {
      return await axios.post(`${this.baseUrl}/channels`, xmlString, {
        headers,
        httpsAgent: this.httpsAgent,
      });
    } catch (err) {
      this._logAxiosError("importChannel (POST /api/channels)", err);
      throw err;
    }
  }

  /**
   * Bulk-import code template libraries (and their templates) that are bundled
   * inside a Mirth channel export's <exportData><codeTemplateLibraries>…</> block.
   *
   * Mirth Administrator does this automatically when a user imports a channel
   * from the GUI, but `POST /api/channels` does NOT do it — it silently drops
   * the <exportData> section, which is why transformers that call global
   * libraries (e.g. `moment()`) fail on a freshly-imported channel.
   *
   * Wire format: the `_bulkUpdate` endpoint declares four separate @Param
   * body parameters (libraries, removedLibraryIds, updatedCodeTemplates,
   * removedCodeTemplateIds), which Mirth dispatches via multipart/form-data,
   * each part being the XML serialisation of the corresponding parameter.
   * Posting a single `application/xml` body to this endpoint responds 415.
   *
   * Each library is sent with its FULL <codeTemplates> children (exactly as
   * they appear in the channel export). An earlier revision tried to replace
   * those children with lightweight `<codeTemplate><id>…</id></codeTemplate>`
   * references, but Mirth 4.5.2's XStream `MigratableConverter` rejects the
   * thin shape with:
   *   "An error occurred while attempting to migrate serialized object
   *    element: codeTemplate"
   * because it can't migrate a <codeTemplate> that lacks its required fields
   * (name, revision, contextSet, codeTemplateType, etc.). Sending the full
   * objects — the same way Mirth Administrator does on the wire — avoids
   * migration entirely. The same templates are ALSO sent via
   * `updatedCodeTemplates` so they are upserted into Mirth's template store.
   *
   * @param {object[]} libraries Array of codeTemplateLibrary objects (xml2js shape)
   * @returns {Promise<boolean>} true if libraries were imported, false if none supplied
   */
  async importCodeTemplateLibraries(libraries) {
    if (!libraries || libraries.length === 0) {
      consoleUtils.info("No code template libraries to import.");
      return false;
    }

    const updatedTemplates = [];
    for (const lib of libraries) {
      const tpls = lib.codeTemplates?.[0]?.codeTemplate || [];
      for (const t of tpls) updatedTemplates.push(t);
    }

    if (updatedTemplates.length === 0) {
      consoleUtils.info(
        "Code template libraries present but contain no templates — nothing to import.",
      );
      return false;
    }

    const builder = new Builder({ headless: true });
    const librariesXml = builder.buildObject({
      list: { codeTemplateLibrary: libraries },
    });
    const updatedCodeTemplatesXml = builder.buildObject({
      list: { codeTemplate: updatedTemplates },
    });
    // `removedLibraryIds` / `removedCodeTemplateIds` are required parameters;
    // we're only adding, so both are empty sets.
    const emptySetXml = builder.buildObject({ set: "" });

    const form = new FormData();
    const xmlPart = { contentType: "application/xml" };
    form.append("libraries", librariesXml, xmlPart);
    form.append("removedLibraryIds", emptySetXml, xmlPart);
    form.append("updatedCodeTemplates", updatedCodeTemplatesXml, xmlPart);
    form.append("removedCodeTemplateIds", emptySetXml, xmlPart);

    const headers = {
      ...this.headers,
      ...form.getHeaders(),
      Accept: "application/xml",
    };

    try {
      await axios.post(
        `${this.baseUrl}/codeTemplateLibraries/_bulkUpdate?override=true`,
        form,
        {
          headers,
          httpsAgent: this.httpsAgent,
          maxBodyLength: Infinity,
          maxContentLength: Infinity,
        },
      );
    } catch (err) {
      this._logAxiosError(
        "importCodeTemplateLibraries (POST /api/codeTemplateLibraries/_bulkUpdate?override=true)",
        err,
      );
      throw err;
    }

    const tplNames = updatedTemplates
      .map((t) => t.name?.[0])
      .filter(Boolean)
      .join(", ");
    consoleUtils.success(
      `Imported ${libraries.length} code template library/libraries` +
        ` with ${updatedTemplates.length} template(s): ${tplNames}`,
    );
    return true;
  }

  _replaceConnectorHeader(conn, headerName, value) {
    const entries = conn.properties?.[0]?.headers?.[0]?.entry || [];
    const wanted = headerName.toLowerCase();

    for (const entry of entries) {
      const name = entry.string?.[0];
      if (typeof name !== "string" || name.toLowerCase() !== wanted) {
        continue;
      }

      const headerValues = entry.list?.[0]?.string;
      if (Array.isArray(headerValues) && headerValues.length > 0) {
        headerValues[0] = value;
      }
    }
  }

  /**
   * Loads the channel XML, rewires its destination-connector URLs / credentials
   * from env, extracts any bundled code-template libraries, and returns BOTH
   * the cleaned-up channel XML (safe to POST to /api/channels) and the
   * extracted libraries (to be imported via `importCodeTemplateLibraries`).
   *
   * The returned channel XML never contains `<exportData>`, even if the
   * source file had it.
   */
  async modifyChannelXml(xmlPath) {
    const hostMap = {
      7: this.config.KEYCLOAK_LOGIN,
      4: this.config.CHECK_MWL_EXIST,
      1: this.config.CHECK_PATIENT_EXIST,
      2: this.config.PATIENT_HTTP_SENDER,
      13: this.config.CHANGESTATUS_MWL,
      15: this.config.CHECK_SERVICE_REQUEST_EXIST,
      12: this.config.CHECK_STUDY_EXIST_IN_FHIR,
      9: this.config.PATCH_END_EXAM_SUPABASE,
      14: this.config.GET_STUDY_MODALITY,
      3: this.config.IMAGINGSTUDY_HTTP_SENDER,
      5: this.config.SERVICE_REQUEST_HTTP_SENDER,
      6: this.config.PROCEDURE_HTTP_SENDER,
      10: this.config.SEND_AUDIT_LOG,
      11: this.config.SEND_AUDIT_TRAIL,
      // metaDataId 19 is the "New object if accession occupied" connector
      // added in the EnhanceNewObjectIfAccessionOccupied revision of the
      // mirth-vision channel. It targets the same FHIR ImagingStudy endpoint
      // as connector 12, just with a different HTTP method + body, so we
      // reuse CHECK_STUDY_EXIST_IN_FHIR for it.
      19: this.config.CHECK_STUDY_EXIST_IN_FHIR,
    };

    let xmlStr = fs.readFileSync(xmlPath, "utf8").trim();
    const baseUrl = this.config.URL.replace(/\/+$/, "");
    xmlStr = xmlStr
      .replaceAll("VISIONX_BASE_URL_FROM_ENV", baseUrl)
      .replaceAll("VISIONX_FHIR_BASE_FROM_ENV", this.config.FHIR_BASE);
    const parsed = await parseStringPromise(xmlStr, {
      explicitArray: true,
      mergeAttrs: false,
    });

    let channelObj;
    if (parsed.channel) {
      channelObj = parsed.channel;
    } else if (parsed.list?.channel?.[0]) {
      channelObj = parsed.list.channel[0];
    } else {
      throw new Error("Unexpected XML structure");
    }

    // Pull out the bundled code-template libraries (if any) and drop exportData
    // so the channel import endpoint doesn't receive a section it will ignore
    // or, in some 4.x builds, reject.
    let libraries = [];
    if (channelObj.exportData?.[0]?.codeTemplateLibraries?.[0]) {
      libraries =
        channelObj.exportData[0].codeTemplateLibraries[0].codeTemplateLibrary ||
        [];
      delete channelObj.exportData;
    }

    // Rewire destination-connector URLs / Keycloak credentials from env.
    const connectors = channelObj.destinationConnectors?.[0]?.connector || [];
    for (const conn of connectors) {
      const id = conn.metaDataId?.[0];
      if (hostMap[id]) {
        conn.properties[0].host[0] = hostMap[id];
        if (id === "7") {
          conn.properties[0].parameters[0].entry[3].list[0].string[0] =
            this.config.KC_PASSWORD;
          conn.properties[0].parameters[0].entry[2].list[0].string[0] =
            this.config.KC_USERNAME;
        }
      }

      if (["9", "10", "11"].includes(id)) {
        this._replaceConnectorHeader(conn, "apiKey", this.config.SUPABASE_KEY);
      }
    }

    const builder = new Builder({ headless: true });
    const channelXml = builder.buildObject({ channel: channelObj });

    return { channelXml, libraries };
  }
}

module.exports = MirthAdapter;
