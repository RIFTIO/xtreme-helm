{{/* Generate basic labels */}}
{{- define "common.verySmall" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "1000Mi" }}
            ephemeral-storage: "5000Mi"
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "10m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "500Mi" }}
            ephemeral-storage: "5000Mi"
{{- end }}

{{- define "common.small.ephemeral3" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "2000Mi" }}
            ephemeral-storage: "1000Mi"
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "20m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "1000Mi" }}
            ephemeral-storage: "1000Mi"
{{- end }}

{{- define "common.small.ephemeral2" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "2000Mi" }}
            ephemeral-storage: "5000Mi"
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "20m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "1000Mi" }}
            ephemeral-storage: "5000Mi"
{{- end }}

{{- define "common.small.ephemeral" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "2000Mi" }}
            ephemeral-storage: "500Mi"
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "20m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "1000Mi" }}
            ephemeral-storage: "500Mi"
{{- end }}

{{- define "common.small" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "2000Mi" }}
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "20m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "1000Mi" }}
{{- end }}

{{- define "common.average.ephemeral" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "8000Mi" }}
            ephemeral-storage: "500Mi"
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "20m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "2000Mi" }}
            ephemeral-storage: "500Mi"
{{- end }}

{{- define "common.average" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "8000Mi" }}
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "20m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "2000Mi" }}
{{- end }}

{{- define "common.big" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "64000Mi" }}
            ephemeral-storage: "5000Mi"
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "50m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "4000Mi" }}
            ephemeral-storage: "5000Mi"
{{- end }}

{{- define "common.veryBig" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "64000Mi" }}
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "50m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "8000Mi" }}
{{- end }}

{{- define "common.colossal" }}
        resources:
          limits:
            memory: {{ (((.Values.resources).limits).memory) | default "128000Mi" }}
          requests:
            cpu: {{ (((.Values.resources).requests).cpu) | default "8000m" }}
            memory: {{ (((.Values.resources).requests).memory) | default "16000Mi" }}
{{- end }}
