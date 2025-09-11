#!/bin/bash

# Базовый URL к репозиторию на GitHub
REPO_URL="https://raw.githubusercontent.com/isitunecon/jenkins-kubernetes/main"

# Списки файлов для каждой версии
SIMPLE_FILES=(
    "app-deployment.yaml"
    "app-service.yaml"
    "mysql-deployment.yaml"
    "mysql-service.yaml"
)

COMPLEX_FILES=(
    "app-deployment.yaml"
    "app-service.yaml"
    "mysql-master.yaml"
    "mysql-slave.yaml"
    "mysql-pvs.yaml"
    "mysql-pvcs.yaml"
    "mysql-services.yaml"
)

# Функция для скачивания файлов
download_files() {
    local folder=$1
    # Конструкция ${!2} позволяет передать имя массива
    local -n files_array=$2 

    echo "-> Скачивание файлов для '$folder' версии..."
    for file in "${files_array[@]}"; do
        echo "   - Загрузка $file"
        # -s (тихий режим), -O (сохранить с оригинальным именем)
        curl -sO "${REPO_URL}/${folder}/${file}"
    done
}

# --- Основная логика скрипта ---

# Меню выбора
echo "Какую конфигурацию подготовить?"
echo "1) Упрощенная (одна база данных)"
echo "2) Усложненная (master-slave репликация БД)"
read -p "Введите 1 или 2: " choice

# Обработка выбора
if [ "$choice" == "1" ]; then
    download_files "simple-setup" SIMPLE_FILES
elif [ "$choice" == "2" ]; then
    download_files "complex-setup" COMPLEX_FILES
else
    echo "Неверный выбор. Выход."
    exit 1
fi

echo
echo "-> Готово! Все необходимые YAML-файлы скачаны в текущую директорию."
echo "-> Теперь отредактируйте их под свой проект (особенно 'image:' в app-deployment.yaml)."
echo "-> После редактирования примените их командой: kubectl apply -f ."
