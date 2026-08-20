{{/*
Copyright 2026 Zhone Inc
*/}}

{{/*
Render the imagePullSecrets block of a pod spec.

As documented in values.yaml, imagePullSecrets may be given globally
(global.imagePullSecrets) or per chart (.Values.imagePullSecrets), and the per
chart value overrides the global one. Nothing is emitted when neither is set,
so installs that pull only public images stay untouched.

Usage from a pod spec whose fields sit at indent 6:

    {{- include "common.imagePullSecrets" . | nindent 6 }}
*/}}
{{- define "common.imagePullSecrets" -}}
{{- $secrets := .Values.imagePullSecrets | default (.Values.global).imagePullSecrets -}}
{{- if $secrets -}}
imagePullSecrets:
{{ toYaml $secrets | indent 2 -}}
{{- end -}}
{{- end -}}
