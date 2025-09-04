{{/* Generate basic labels */}}
{{- define "runAsUserGroup" }}
  runAsUser: {{ (((.Values.global).userGroupConfig).runAsUser) | default 3015 }}
  runAsGroup: {{ (((.Values.global).userGroupConfig).runAsGroup) | default 3064 }}
{{- end }}
{{- define "runAsFsGroup" }}
  fsGroup: {{ (((.Values.global).fsGroupConfig).fsGroup) | default 3064 }}
{{- end }}
