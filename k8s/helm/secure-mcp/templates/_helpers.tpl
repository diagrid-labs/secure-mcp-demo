{{/* secure-mcp shared template helpers */}}

{{- define "secure-mcp.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/* Hostname of the bitnami postgresql Service inside the same namespace. */}}
{{- define "secure-mcp.pgHost" -}}
{{- printf "%s-postgresql" .Release.Name -}}
{{- end -}}

{{/* Hostname of the bitnami keycloak Service inside the same namespace. */}}
{{- define "secure-mcp.keycloakHost" -}}
{{- printf "%s-keycloak" .Release.Name -}}
{{- end -}}

{{/* Diagrid Cloud integration is TBD pending the cluster→Cloud
     connectivity model (likely an outbound-tunnel agent per pod, not
     in-cluster Dapr/Conductor). This helper is intentionally empty
     until that model is decided. See k8s/CATALYST.md. */}}
{{- define "secure-mcp.catalystAnnotations" -}}
{{- /* no annotations until Diagrid Cloud model is chosen */ -}}
{{- end -}}
