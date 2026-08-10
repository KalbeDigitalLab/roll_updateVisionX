const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

async function deployHelper(env) {
  const basePath = process.env.LOCAL_BASE_PATH;
  if (!basePath) {
    throw new Error("Missing required environment variable: LOCAL_BASE_PATH");
  }

  const yamlPath = path.join(basePath, "12-helper.yaml");

  if (!fs.existsSync(basePath)) {
    fs.mkdirSync(basePath, { recursive: true });
  }

  // Make namespace (Abaikan error jika sudah ada) — needed before the secret
  // step below, since namespace creation otherwise only happens declaratively
  // via the Namespace object in yamlContent, applied later.
  try {
    execSync("kubectl create namespace elvasoft-helper", { stdio: "ignore" });
  } catch (e) {
    /* ignore */
  }

  // Only create secret regcred if it isn't already there — check first
  // instead of blind-create-and-ignore, so a real creation failure (e.g.
  // /root/.docker/config.json missing/stale) surfaces instead of being
  // silently swallowed alongside the harmless "already exists" case.
  let regcredExists = true;
  try {
    execSync("kubectl get secret regcred -n elvasoft-helper", {
      stdio: "ignore",
    });
  } catch (e) {
    regcredExists = false;
  }

  if (!regcredExists) {
    try {
      execSync(
        "kubectl create secret generic regcred --from-file=.dockerconfigjson=/root/.docker/config.json --type=kubernetes.io/dockerconfigjson -n elvasoft-helper",
        { stdio: "ignore" },
      );
      consoleUtils.info("regcred secret created in elvasoft-helper.");
    } catch (e) {
      consoleUtils.warn(
        "Failed to create regcred secret in elvasoft-helper — check /root/.docker/config.json exists on this host and is logged into the ACR registry.",
      );
    }
  }

  const yamlContent = `apiVersion: v1
kind: Namespace
metadata:
  name: elvasoft-helper
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: elvasoft-helper
  namespace: elvasoft-helper
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: elvasoft-helper
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["get", "create"]
- apiGroups: ["apps"]
  resources: ["deployments", "deployments/scale"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: elvasoft-helper
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: elvasoft-helper
subjects:
- kind: ServiceAccount
  name: elvasoft-helper
  namespace: elvasoft-helper
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elvasoft-helper
  namespace: elvasoft-helper
  labels:
    app: elvasoft-helper
spec:
  replicas: 1
  selector:
    matchLabels:
      app: elvasoft-helper
  template:
    metadata:
      labels:
        app: elvasoft-helper
    spec:
      serviceAccountName: elvasoft-helper
      imagePullSecrets:
      - name: regcred
      containers:
      - name: elvasoft-helper
        image: kalbedevops.azurecr.io/elvasoft/helper:1.0.0
        ports:
        - containerPort: 13131
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        readinessProbe:
          tcpSocket:
            port: 13131
          initialDelaySeconds: 15
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 13131
          initialDelaySeconds: 60
          periodSeconds: 20
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: elvasoft-helper-service
  namespace: elvasoft-helper
spec:
  selector:
    app: elvasoft-helper
  ports:
  - name: http
    protocol: TCP
    port: 13131
    targetPort: 13131
    nodePort: 31313
  type: NodePort`;

  try {
    fs.writeFileSync(yamlPath, yamlContent);
    consoleUtils.info(`✅ 12-helper.yaml berhasil di-generate di ${yamlPath}`);

    // Apply YAML
    execSync(`kubectl apply -f ${yamlPath}`, { stdio: "inherit" });
    consoleUtils.success("✅ Kubernetes Helper Deployment Selesai.");
  } catch (error) {
    consoleUtils.error(`Gagal melakukan deploy Helper: ${error.message}`);
  }
}

module.exports = deployHelper;
