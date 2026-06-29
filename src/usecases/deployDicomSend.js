// src/usecases/deployDicomSend.js
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

async function deployDicomSend(env) {
  const basePath = requiredEnv("LOCAL_BASE_PATH");
  const yamlPath = path.join(basePath, "13-elvasoft-dicom-proxy.yaml");
  const baseUrl = requiredEnv("URL").replace(/\/+$/, "");

  if (!fs.existsSync(basePath)) {
    fs.mkdirSync(basePath, { recursive: true });
  }

  try {
    consoleUtils.info(
      "🔄 Menyiapkan namespace dan secret untuk Dicom Proxy...",
    );
    // Make namespace (Abaikan error jika sudah ada)
    try {
      execSync("kubectl create namespace elvasoft-dicom-proxy", {
        stdio: "ignore",
      });
    } catch (e) {
      /* ignore */
    }

    // Create secret regcred (Abaikan error jika sudah ada)
    try {
      execSync(
        "kubectl create secret generic regcred --from-file=.dockerconfigjson=/root/.docker/config.json --type=kubernetes.io/dockerconfigjson -n elvasoft-dicom-proxy",
        { stdio: "ignore" },
      );
    } catch (e) {
      /* ignore */
    }

    // Template YAML dari dokumen VisionX
    const yamlContent = `apiVersion: v1
kind: Namespace
metadata:
  name: elvasoft-dicom-proxy
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elvasoft-dicom-proxy
  namespace: elvasoft-dicom-proxy
  labels:
    app: elvasoft-dicom-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: elvasoft-dicom-proxy
  template:
    metadata:
      labels:
        app: elvasoft-dicom-proxy
    spec:
      imagePullSecrets:
      - name: regcred
      containers:
      - name: elvasoft-dicom-proxy
        image: kalbedevops.azurecr.io/vision/elvasoft-dicom-proxy:1.0.47
        ports:
        - containerPort: 8000
          name: http
        env:
        - name: SUPABASE_URL
          value: "${requiredEnv("SUPABASE_URL")}"
        - name: SUPABASE_SERVICE_ROLE_KEY
          value: "${requiredEnv("SUPABASE_KEY")}"
        - name: DCM4CHEE_AET
          value: "${requiredEnv("DCM_AET")}"
        - name: DCM4CHEE_BASE_URL
          value: "${baseUrl}/dcm4chee-arc"
        - name: KEYCLOAK_TOKEN_URL
          value: "${requiredEnv("KC_TOKEN_URL")}"
        - name: KEYCLOAK_CLIENT_ID
          value: "${requiredEnv("KC_CLIENT_ID")}"
        - name: KEYCLOAK_USERNAME
          value: "${requiredEnv("KC_USERNAME")}"
        - name: KEYCLOAK_PASSWORD
          value: "${requiredEnv("KC_PASSWORD")}"
        - name: LOCAL_AE_TITLE
          value: "ELVASOFT_PROXY"
        - name: JOB_ROOT
          value: "/tmp/elvasoft-dicom-proxy"
        - name: DCMTK_TIMEOUT
          value: "300"
        - name: JOB_RETENTION_HOURS
          value: "24"
        - name: STOW_RS_TIMEOUT
          value: "7200"
        - name: WADO_RS_TIMEOUT
          value: "300"
        - name: DOWNLOAD_VIEWER_TIMEOUT
          value: "600"
        - name: PYTHONUNBUFFERED
          value: "1"
        - name: DICOM_SEND_MEMORY_BUDGET_MB
          value: "800"
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: false
---
apiVersion: v1
kind: Service
metadata:
  name: elvasoft-dicom-proxy-service
  namespace: elvasoft-dicom-proxy
spec:
  type: NodePort
  selector:
    app: elvasoft-dicom-proxy
  ports:
  - name: http
    protocol: TCP
    port: 8000
    targetPort: 8000
    nodePort: 30080`;

    fs.writeFileSync(yamlPath, yamlContent);
    consoleUtils.info(
      `✅ 13-elvasoft-dicom-proxy.yaml berhasil di-generate di ${yamlPath}`,
    );

    execSync(`kubectl apply -f ${yamlPath}`, { stdio: "inherit" });
    consoleUtils.success(
      "✅ Dicom Proxy Deployment Selesai. Jangan lupa allow port 30080 di firewall jika belum!",
    );
  } catch (error) {
    consoleUtils.error(`Gagal melakukan deploy Dicom Proxy: ${error.message}`);
  }
}

module.exports = deployDicomSend;
