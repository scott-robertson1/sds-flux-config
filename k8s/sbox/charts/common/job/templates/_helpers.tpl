{{/*
ref: https://github.com/helm/charts/blob/master/stable/postgresql/templates/_helpers.tpl
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
*/}}
{{- define "hmcts.releaseName" -}}
{{- if .Values.releaseNameOverride -}}
{{- .Values.releaseNameOverride | trunc 53 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 53 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "hmcts.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{/*
Create meta data using releasename and chart name templates.
*/}}
{{- define "job.metadata" -}}
metadata:
  name: {{ include "hmcts.releaseName" . }}
  labels:
    app.kubernetes.io/name: {{ include "hmcts.releaseName" . }}
    helm.sh/chart: {{ include "hmcts.chart" . }}
    app.kubernetes.io/instance: {{ template "hmcts.releaseName" . }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Add labels to add to template spec.
*/}}
{{- define "job.labels" -}}
{{- if .Values.labels }}
{{- range $key, $val := .Values.labels }}
{{ $key }}: {{ $val }}
{{- end}}
{{- end}}
{{- end -}}



{{- define "java.tests.meta" -}}
metadata:
  name: {{ .Release.Name }}-{{ .Values.task }}{{ .Values.type }}-job
  labels:
    app.kubernetes.io/managed-by: {{ .Release.Service }}
    app.kubernetes.io/instance: {{ .Release.Name }}-{{ .Values.task }}{{ .Values.type }}
    helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
    app.kubernetes.io/name: {{ template "hmcts.releaseName" . }}-{{ .Values.task }}{{ .Values.type }}
{{- end -}}

{{- define "java.tests.header" -}}
apiVersion: batch/v1
kind: Job
{{ template "java.tests.meta" . }}
    {{- if .Values.aadIdentityName }}
    aadpodidbinding: {{ .Values.aadIdentityName }}
    {{- end }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation 
{{- end -}}







{{- define "job.tests.spec" -}}
{{- if .Values.testsConfig.backoffLimit }}
backoffLimit: {{ .Values.testsConfig.backoffLimit }}
{{- end }}
{{- if .Values.testsConfig.activeDeadlineSeconds }}
activeDeadlineSeconds: {{ .Values.testsConfig.activeDeadlineSeconds }}
{{- end }}
{{- if .Values.testsConfig.ttlSecondsAfterFinished }}
ttlSecondsAfterFinished: {{ .Values.testsConfig.ttlSecondsAfterFinished }}
{{- end }}
template:
  metadata:
    labels:
      app.kubernetes.io/name: {{ include "hmcts.releaseName" . }}
      {{- include "job.labels" . | indent 6}}
      {{- if .Values.aadIdentityName }}
      aadpodidbinding: {{ .Values.aadIdentityName }}
      {{- end }}
    
  spec:
    {{- if and .Values.testsConfig.keyVaults .Values.global.enableKeyVaults }}
    volumes:
      {{- $globals := .Values.global }}
      {{- $aadIdentityName := .Values.aadIdentityName }}
      {{- range $key, $value := .Values.testsConfig.keyVaults }}
      - name: vault-{{ $key }}
        flexVolume:
          driver: "azure/kv"
          {{- if not $aadIdentityName }}
          secretRef:
            name: {{ default "kvcreds" $value.secretRef }}
          {{- end }}
          options:
            usepodidentity: "{{ if $aadIdentityName }}true{{ else }}false{{ end}}"
            tenantid: {{ $globals.tenantId }}
            keyvaultname: {{if $value.excludeEnvironmentSuffix }}{{ $key | quote }}{{else}}{{ printf "%s-%s" $key $globals.environment }}{{ end }}
            keyvaultobjectnames: {{ $value.secrets | join ";" | quote }}  #"some-username;some-password"
            keyvaultobjecttypes: {{ trimSuffix ";" (repeat (len $value.secrets) "secret;") | quote }} # OPTIONS: secret, key, cert
      {{- end }}
    {{- end }}
    securityContext:
      runAsUser: 1000
      fsGroup: 1000
    restartPolicy: Never
    containers:
      - name: tests
        image: {{ .Values.tests.image }}
        {{- if and .Values.testsConfig.keyVaults .Values.global.enableKeyVaults }}
        {{ $args := list }}
        {{- range $key, $value := .Values.testsConfig.keyVaults -}}{{- range $secret, $var := $value.secrets -}} {{ $args = append $args (printf "%s=/mnt/secrets/%s/%s" $var $key $secret | quote) }} {{- end -}}{{- end -}}
        args: [{{ $args | join "," }}]
        {{- end }}
        securityContext:
          allowPrivilegeEscalation: false
        {{- if or .Values.tests.environment .Values.testsConfig.environment }}
        {{- $envMap := dict "TEST_URL" "" -}}
        {{- if .Values.testsConfig.environment -}}{{- range $key, $value := .Values.testsConfig.environment -}}{{- $_ := set $envMap $key $value -}}{{- end -}}{{- end -}}
        {{- if .Values.tests.environment -}}{{- range $key, $value := .Values.tests.environment -}}{{- $_ := set $envMap $key $value -}}{{- end -}}{{- end }}
        env:
          - name: TASK
            value: {{ .Values.task | quote }}
          - name: TASK_TYPE
            value: {{ .Values.type | quote }}
          # - name: SLACK_WEBHOOK
          #   valueFrom:
          #     secretKeyRef:
          #       name: tests-values
          #       key: slack-webhook
        {{- range $key, $val := $envMap }}
          - name: {{ $key }}
            value: {{ tpl ($val | quote) $ }}
        {{- end }}
        {{- end }}
        {{- if and .Values.testsConfig.keyVaults .Values.global.enableKeyVaults }}
        volumeMounts:
          {{- range $key, $value := .Values.testsConfig.keyVaults }}
          - name: vault-{{ $key }}
            mountPath: /mnt/secrets/{{ $key }}
            readOnly: true
          {{- end }}
        {{- end }}
        resources:
          requests:
            memory: "{{ if .Values.tests.memoryRequests }}{{ .Values.tests.memoryRequests }}{{ else }}{{ .Values.testsConfig.memoryRequests }}{{ end }}"
            cpu: "{{ if .Values.tests.cpuRequests }}{{ .Values.tests.cpuRequests }}{{ else }}{{ .Values.testsConfig.cpuRequests }}{{ end }}"
          limits:
            memory: "{{ if .Values.tests.memoryLimits }}{{ .Values.tests.memoryLimits }}{{ else }}{{ .Values.testsConfig.memoryLimits }}{{ end }}"
            cpu: "{{ if .Values.tests.cpuLimits }}{{ .Values.tests.cpuLimits }}{{ else }}{{ .Values.testsConfig.cpuLimits }}{{ end }}"
    {{- end -}}

