#!/bin/bash

# ==============================================================================
# Скрипт для создания файла Jenkinsfile к практической работе по Jenkins.
# Создает готовый Jenkinsfile с пайплайном для деплоя в Kubernetes.
# ВАЖНО: Используется heredoc с одинарными кавычками ('EOF'), чтобы
# переменные Groovy (например, ${...}) и Jenkins (например, $(...))
# не интерпретировались оболочкой bash.
# ==============================================================================

# --- Шаг 1: Определяем, куда сохранять файл ---
if [ -d "$HOME/Desktop" ]; then
    TARGET_DIR="$HOME/Desktop"
    echo "Рабочий стол найден. Файл будет сохранен в: $TARGET_DIR"
else
    TARGET_DIR="$HOME"
    echo "Папка 'Desktop' не найдена. Файл будет сохранен в домашней директории: $TARGET_DIR"
fi
echo ""

# --- Шаг 2: Создание файла Jenkinsfile.groovy с обновленным пайплайном ---
JENKINSFILE_PATH="$TARGET_DIR/Jenkinsfile.groovy"

# Используем Heredoc с кавычками 'EOF', чтобы переменные внутри скрипта не были
# интерпретированы оболочкой bash при создании файла.
cat <<'EOF' > "$JENKINSFILE_PATH"
pipeline {
    agent {
        kubernetes {
            yaml '''
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
                    args: ['$(JENKINS_SECRET)', '$(JENKINS_NAME)']
                    resources:
                      requests:
                        cpu: "50m"
                        memory: "256Mi"
            '''
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

                        // Проверяем DNS резолв
                        def dnsStatus = sh(script: "nslookup ${mysqlAddress}", returnStatus: true)
                        if (dnsStatus != 0) {
                            echo "DNS резолв неуспешен для ${mysqlAddress}"
                            error("База данных недоступна - DNS ошибка! Деплой остановлен.")
                        }

                        // Проверяем существование endpoint'а
                        def endpointCheck = sh(script: "kubectl get endpoints mysql-master -n default -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null", returnStdout: true).trim()
                        if (endpointCheck == "") {
                            echo "Endpoint mysql-master не имеет активных адресов"
                            sh 'kubectl get endpoints mysql-master -n default -o wide'
                            error("База данных недоступна - нет активных endpoint'ов! Деплой остановлен.")
                        }

                        // Проверяем статус подов базы данных
                        def podStatus = sh(script: "kubectl get pods -l app=mysql-master -n default -o jsonpath='{.items[0].status.phase}' 2>/dev/null", returnStdout: true).trim()
                        if (podStatus != "Running") {
                            echo "Pod базы данных не в статусе Running: ${podStatus}"
                            sh 'kubectl get pods -A -l app=mysql-master -o wide'
                            error("База данных недоступна - pod не запущен! Деплой остановлен.")
                        }

                        // Альтернативная проверка соединения через telnet (более надежно)
                        def dbStatus = sh(script: "timeout 10 sh -c 'echo > /dev/tcp/${mysqlAddress}/3306' 2>/dev/null", returnStatus: true)

                        if (dbStatus == 0) {
                            echo "База данных доступна (${endpointCheck}:3306)"
                        } else {
                            // Дополнительная проверка через kubectl port-forward
                            echo "Прямое соединение неуспешно, проверяем через kubectl..."
                            def kubectlTest = sh(script: "kubectl exec -n default deployment/mysql-master -- mysql -u root -psecret -e 'SELECT 1' 2>/dev/null", returnStatus: true)

                            if (kubectlTest == 0) {
                                echo "База данных доступна через kubectl exec"
                            } else {
                                echo "База данных недоступна через kubectl exec"
                                sh 'kubectl get pods -A -l app=mysql-master -o wide'
                                sh 'kubectl describe pods -l app=mysql-master -n default'
                                error("База данных недоступна! Деплой остановлен.")
                            }
                        }
                    }
                }
            }
        }

        stage('Test Frontend') {
            steps {
                container('tools') {
                    script {
                        echo "Проверка доступности фронтенда..."

                        // Сначала проверяем, что сервис существует
                        def serviceCheck = sh(script: "kubectl get service crudback-service -n default -o jsonpath='{.spec.clusterIP}' 2>/dev/null", returnStdout: true).trim()
                        if (serviceCheck == "") {
                            echo "Сервис crudback-service не найден"
                            error("Фронтенд сервис недоступен! Деплой остановлен.")
                        }

                        // Проверяем External IP сервиса LoadBalancer
                        def externalIP = sh(script: "kubectl get service crudback-service -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null", returnStdout: true).trim()
                        if (externalIP == "") {
                            echo "External IP еще не назначен LoadBalancer'у, ждем..."
                            sleep(time: 30, unit: "SECONDS")
                            externalIP = sh(script: "kubectl get service crudback-service -n default -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null", returnStdout: true).trim()
                        }

                        if (externalIP != "") {
                            echo "LoadBalancer External IP: ${externalIP}"
                            def frontendStatus = sh(script: "curl -sSf http://${externalIP}:80 -m 10 -o /dev/null -w 'HTTP Code: %{http_code}'", returnStatus: true)

                            if (frontendStatus == 0) {
                                echo "Фронтенд доступен по External IP"
                            } else {
                                echo "Фронтенд недоступен по External IP. Код ошибки: ${frontendStatus}"
                                // Проверяем поды приложения
                                sh 'kubectl get pods -n default -l app=crudback -o wide'
                                sh 'kubectl describe service crudback-service -n default'
                                error("Фронтенд недоступен! Деплой остановлен.")
                            }
                        } else {
                            echo "External IP не назначен, проверяем через ClusterIP..."
                            def clusterIP = sh(script: "kubectl get service crudback-service -n default -o jsonpath='{.spec.clusterIP}'", returnStdout: true).trim()
                            def clusterPort = sh(script: "kubectl get service crudback-service -n default -o jsonpath='{.spec.ports[0].port}'", returnStdout: true).trim()

                            // Тестируем через ClusterIP изнутри кластера
                            def internalTest = sh(script: "curl -sSf http://${clusterIP}:${clusterPort}/health -m 10 2>/dev/null || curl -sSf http://${clusterIP}:${clusterPort} -m 10 -o /dev/null", returnStatus: true)

                            if (internalTest == 0) {
                                echo "Фронтенд доступен через ClusterIP (${clusterIP}:${clusterPort})"
                            } else {
                                echo "Фронтенд недоступен через ClusterIP"
                                sh 'kubectl get pods -n default -l app=crudback -o wide'
                                sh 'kubectl describe service crudback-service -n default'
                                error("Фронтенд недоступен! Деплой остановлен.")
                            }
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

                    // Проверяем, что поды действительно запущены
                    script {
                        // Получаем правильный selector из deployment
                        def deploymentSelector = sh(script: 'kubectl get deployment crudback-app -n default -o jsonpath="{.spec.selector.matchLabels}" | grep -o \'"app":"[^"]*"\' | cut -d\'"\' -f4', returnStdout: true).trim()
                        echo "Deployment selector: app=${deploymentSelector}"

                        def podCount = sh(script: "kubectl get pods -n default -l app=${deploymentSelector} --no-headers | wc -l", returnStdout: true).trim()
                        echo "Количество подов приложения: ${podCount}"

                        if (podCount.toInteger() == 0) {
                            echo "Поды приложения не найдены!"
                            sh 'kubectl get pods -n default'
                            echo "Проверяем все поды приложения без фильтра:"
                            sh 'kubectl get pods -n default | grep crudback || echo "Нет подов с именем crudback"'
                            error("Деплой неуспешен - поды приложения не запущены!")
                        } else {
                            echo "Найдено ${podCount} подов приложения"
                            sh "kubectl get pods -n default -l app=${deploymentSelector} -o wide"
                        }
                    }
                }
            }
        }

        stage('Final Health Check') {
            steps {
                container('tools') {
                    script {
                        echo "Финальная проверка работоспособности..."

                        // Получаем правильный selector из deployment
                        def deploymentSelector = sh(script: 'kubectl get deployment crudback-app -n default -o jsonpath="{.spec.selector.matchLabels}" | grep -o \'"app":"[^"]*"\' | cut -d\'"\' -f4', returnStdout: true).trim()

                        // Проверяем статус подов
                        def readyPods = sh(script: "kubectl get pods -n default -l app=${deploymentSelector} -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | grep -o true | wc -l", returnStdout: true).trim()
                        def totalPods = sh(script: "kubectl get pods -n default -l app=${deploymentSelector} --no-headers | wc -l", returnStdout: true).trim()

                        echo "Готовых подов: ${readyPods}/${totalPods}"

                        if (readyPods.toInteger() != totalPods.toInteger() || totalPods.toInteger() == 0) {
                            echo "Не все поды готовы к работе!"
                            sh "kubectl describe pods -n default -l app=${deploymentSelector}"
                            error("Деплой неуспешен - не все поды готовы!")
                        } else {
                            echo "Все поды готовы к работе"
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            echo "Пайплайн завершён"
            container('tools') {
                // Собираем диагностическую информацию
                echo "=== ДИАГНОСТИЧЕСКАЯ ИНФОРМАЦИЯ ==="
                sh 'kubectl get all -n default || true'
                sh 'kubectl get events -n default --sort-by=".lastTimestamp" | tail -10 || true'
            }
        }
        success {
            echo "Деплой успешно завершен!"
        }
        failure {
            echo "Деплой завершился с ошибками"
            container('tools') {
                // Дополнительная диагностика при ошибке
                echo "=== ДИАГНОСТИКА ОШИБОК ==="
                sh 'kubectl get pods -n default -o wide || true'
                sh 'kubectl describe deployment crudback-app -n default || true'
                sh 'kubectl logs -l app=crudback -n default --tail=50 || true'
            }
        }
        unstable {
            echo "Деплой завершился с предупреждениями"
        }
    }
}
EOF

echo "Файл 'Jenkinsfile.groovy' успешно создан по пути: $JENKINSFILE_PATH"
echo ""

# --- Шаг 3: Итоговые инструкции ---
echo "-------------------------------------------------------------"
echo "Подготовка завершена! Ваш следующий шаг:"
echo "При настройке Pipeline в Jenkins, скопируйте содержимое файла:"
echo "$JENKINSFILE_PATH"
echo "-------------------------------------------------------------"
