const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const consoleUtils = require("../utils/consoleUtils");

/**
 * Deploys the Kubernetes Helper.
 *
 * The manifest below is only a template for a FRESH install: it is written out
 * when the helper yaml does not exist yet. An existing manifest is never
 * overwritten — it holds whatever image tag the operator set and any manual
 * edits, which a regenerated file would silently reset (the template pins
 * image tag 1.0.0, which predates the /ris-log endpoints). Existing files are
 * patched in place instead (see LocalAdapter.ensureHelperEventsRule).
 */
async function deployHelper(adapter, env) {
  const basePath = env.LOCAL_BASE_PATH;
  if (!basePath) {
    throw new Error("Missing required environment variable: LOCAL_BASE_PATH");
  }

  const yamlFile = env.ELVASOFT_HELPER_YAML_FILE;
  const yamlPath = path.join(basePath, yamlFile);

  if (!fs.existsSync(basePath)) {
    fs.mkdirSync(basePath, { recursive: true });
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
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
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
    // True when ensureHelperEventsRule already applied the patched file.
    let appliedByPatch = false;

    if (fs.existsSync(yamlPath)) {
      consoleUtils.info(
        `${yamlFile} sudah ada di ${yamlPath} — tidak ditimpa (image tag dan edit manual dipertahankan).`,
      );
      appliedByPatch = await adapter.ensureHelperEventsRule(yamlFile);
    } else {
      fs.writeFileSync(yamlPath, yamlContent);
      consoleUtils.info(`✅ ${yamlFile} berhasil di-generate di ${yamlPath}`);
    }

    if (!appliedByPatch) {
      execSync(`kubectl apply -f ${yamlPath}`, { stdio: "inherit" });
    }
    consoleUtils.success("✅ Kubernetes Helper Deployment Selesai.");
  } catch (error) {
    consoleUtils.error(`Gagal melakukan deploy Helper: ${error.message}`);
  }
}

module.exports = deployHelper;
