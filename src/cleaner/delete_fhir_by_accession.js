const consoleUtils = require("../utils/consoleUtils");

async function deleteFhirByAccession(askHelper) {
  const baseUrl = process.env.FHIR_BASE;
  if (!baseUrl) {
    throw new Error("Missing required environment variable: FHIR_BASE");
  }

  const token = process.env.BEARER_TOKEN || "";
  const headers = token ? { Authorization: `Bearer ${token}` } : {};

  // Daftar resource sesuai dengan urutan di script bash
  const resources = [
    "DiagnosticReport",
    "Observation",
    "ImagingStudy",
    "Procedure",
    "ServiceRequest",
  ];

  // Meminta input accession numbers dari user secara interaktif
  const accessionsInput = await askHelper.ask(
    "Masukkan Accession Number yang ingin dihapus (pisahkan dengan koma jika > 1, biarkan kosong untuk skip): ",
  );

  if (!accessionsInput || accessionsInput.trim() === "") {
    consoleUtils.warn(
      "Tidak ada accession yang dimasukkan. Skip proses delete.",
    );
    return;
  }

  const accessions = accessionsInput
    .split(",")
    .map((a) => a.trim())
    .filter((a) => a);

  consoleUtils.info(`Memulai proses delete ke ${baseUrl} ...`);

  for (const acc of accessions) {
    consoleUtils.section(`Accession: ${acc}`);

    for (const res of resources) {
      const url = `${baseUrl}/${res}/${acc}`;

      try {
        const response = await fetch(url, {
          method: "DELETE",
          headers: headers,
        });

        const code = response.status;

        if ([200, 202, 204].includes(code)) {
          consoleUtils.success(`✓ ${res}/${acc} → ${code}`);
        } else if (code === 404) {
          consoleUtils.info(`• ${res}/${acc} → 404 (not found, OK)`);
        } else {
          consoleUtils.warn(`⚠ ${res}/${acc} → ${code} (unexpected)`);
        }
      } catch (error) {
        consoleUtils.error(`Gagal menghapus ${res}/${acc}: ${error.message}`);
      }
    }
  }

  consoleUtils.success("Proses delete FHIR resource selesai.");
}

module.exports = deleteFhirByAccession;
