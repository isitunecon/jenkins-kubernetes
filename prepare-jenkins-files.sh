#!/bin/bash

# ==============================================================================
# Скрипт для подготовки файлов к практической работе по Jenkins
# 1. Копирует kubeconfig для доступа к Kubernetes из Jenkins.
# 2. Создает Jenkinsfile с готовым пайплайном из практической работы.
# ВАЖНО: Добавлено экранирование '$' для переменных jenkins-agent.
# ==============================================================================

# --- Шаг 1: Определяем, куда сохранять файлы ---
if [ -d "$HOME/Desktop" ]; then
    TARGET_DIR="$HOME/Desktop"
    echo "Рабочий стол найден. Файлы будут сохранены в: $TARGET_DIR"
else
    TARGET_DIR="$HOME"
    echo "Папка 'Desktop' не найдена. Файлы будут сохранены в домашней директории: $TARGET_DIR"
fi
echo ""

# --- Шаг 2: Подготовка файла config.txt для Jenkins Credentials ---
KUBE_CONFIG_SOURCE="$HOME/.kube/config"
KUBE_CONFIG_DEST="$TARGET_DIR/config.txt"

if [ ! -f "$KUBE_CONFIG_SOURCE" ]; then
    echo "❌ Ошибка: Файл $KUBE_CONFIG_SOURCE не найден."
    echo "Убедитесь, что ваш кластер Kubernetes настроен, прежде чем запускать скрипт."
    exit 1
fi

cp "$KUBE_CONFIG_SOURCE" "$KUBE_CONFIG_DEST"
echo "✅ Файл 'config.txt' успешно создан по пути: $KUBE_CONFIG_DEST"
echo "   Используйте его для загрузки в Jenkins Credentials."
echo ""

# --- Шаг 3: Создание файла Jenkinsfile.groovy с исправленным пайплайном ---
JENKINSFILE_PATH="$TARGET_DIR/Jenkinsfile.groovy"

# Используем Heredoc с кавычками 'EOF', чтобы переменные $(...) внутри скрипта не были
# интерпретированы оболочкой bash при создании файла.
cat <<'EOF' > "$JENKINSFILE_PATH"
pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: tools
    image: alpine/k8s:1.27.4
    command: ['cat']
    tty: true
    resources:
      requests:
        cpu: "100m"
        memory: "128Mi"
  - name: jnlp
    image: jenkins/inbound-agent:latest
    # ИСПРАВЛЕНО: Добавлены обратные слэши для экранирования знака доллара
    args: ['\$(JENKINS_SECRET)', '\$(JENKINS_NAME)']
    resources:
      requests:
        cpu: "50m"
        memory: "256Mi"
"""
        }
    }
    environment {
        KUBECONFIG = credentials('kubeconfig-secret-id')
    }
    stages {
        stage('Check Kubernetes') {
            steps {
                container('tools') {
                    sh 'kubectl get nodes'
                    sh 'kubectl get namespaces'
                }
            }
        }
        stage('Test Database Connection') {
            steps {
                container('tools') {
                    script {
                        echo "Проверка доступности базы данных..."
                        def mysqlAddress = "mysql-master.default.svc.cluster.local"
                        echo "Попытка подключения к: ${mysqlAddress}:3306"
                        def dbStatus = sh(script: "nc -zv ${mysqlAddress} 3306 -w 10 >/dev/null 2>&1", returnStatus: true)
                        if (dbStatus == 0) {
                            echo "База данных доступна"
                        } else {
                            echo "База данных недоступна. Код ошибки: ${dbStatus}"
                            // Дополнительная диагностика
                            sh "nslookup ${mysqlAddress} || echo 'DNS lookup failed'"
                            sh 'kubectl get endpoints mysql-master -o wide'
                            sh 'kubectl get pods -l app=mysql-master -o wide'
                        }
                    }
                }
            }
        }
        stage('Test Frontend') {
            steps {
                container('tools') {
                    script {
                        def frontendStatus = sh(script: "curl -sSf http://192.168.0.100:80 -o /dev/null -w 'HTTP Code: %{http_code}'", returnStatus: true)
                        if (frontendStatus == 0) {
                            echo "Фронт доступен"
                        } else {
                            echo "Фронт недоступен. Код ошибки: ${frontendStatus}"
                        }
                    }
                }
            }
        }
        stage('Deploy Application') {
            steps {
                container('tools') {
                    echo "Деплой приложения..."
                    // Деплой в namespace - default
                    sh 'kubectl set image deployment/crudback-app crudback=snezhana02/crudback -n default'
                    // Проверка результата деплоя
                    echo "Проверяем статус деплоя..."
                    sh 'kubectl rollout status deployment/crudback-app -n default --timeout=120s'
                    sh 'kubectl get deployments -n default'
                    sh 'kubectl get pods -n default -l app=crudback-app'
                }
            }
        }
    }
    post {
        always {
            echo "Пайплайн завершён"
        }
        success {
            echo "Деплой успешно завершен!"
        }
        failure {
            echo "Деплой завершился с ошибками"
        }
    }
}
EOF

echo "✅ Файл 'Jenkinsfile.groovy' успешно создан по пути: $JENKINSFILE_PATH"
echo ""

# --- Шаг 4: Итоговые инструкции ---
echo "-------------------------------------------------------------"
echo "Подготовка завершена! Ваши дальнейшие действия:"
echo "1. При создании Credentials в Jenkins, загрузите файл: $KUBE_CONFIG_DEST"
echo "2. При настройке Pipeline, скопируйте содержимое файла: $JENKINSFILE_PATH"
echo "-------------------------------------------------------------"
