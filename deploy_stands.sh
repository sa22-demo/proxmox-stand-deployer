#!/bin/bash
nbr=3  # Количество мостов на стенд (ISP-RTR, RTR-SRV, RTR-CLI)

# Основные функции
configure_network() {
    local i=$1
    echo "Создание сетевых мостов для стенда $i"
    local base_br=$((START_ID + 10 * i))
    for ((br = base_br; br < base_br + nbr; br++)); do
        if ! grep -q "vmbr$br" /etc/network/interfaces; then
            cat >> "/etc/network/interfaces" << EOF

auto vmbr$br
iface vmbr$br inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0

EOF
            echo "Мост vmbr$br создан"
        else
            echo "Мост vmbr$br уже существует"
        fi
    done
    echo -e "\033[32m Выполнено \033[0m"
}

deploy_user_stand() {
    local i=$1
    echo "Развёртывание стенда для рабочего места $i"
    local base_vm=$((START_ID + 10 * i))
    local base_br=$((START_ID + 10 * i))
    
    # Создаем виртуальные машины
    qm clone "$ISP"  "$base_vm"      --name "ISP-$base_vm" && \
    qm clone "$RTR"  "$((base_vm+1))" --name "RTR-$base_vm" && \
    qm clone "$SRV"  "$((base_vm+2))" --name "SRV-$base_vm" && \
    qm clone "$CLI"  "$((base_vm+3))" --name "CLI-$base_vm" || {
        echo "Ошибка при создании ВМ"
        return 1
    }

    # Настраиваем сетевое оборудование
    {
        # ISP: внешний интерфейс (vmbr0) + внутренний (vmbrX)
        qm set "$base_vm"    --net0 e1000,bridge=vmbr0 \
                             --net1 e1000,bridge=vmbr"$base_br"
        
        # RTR: 
        #   eth0: к ISP (vmbrX)
        #   eth1: к SRV (vmbrX+1)
        #   eth2: к CLI (vmbrX+2)
        qm set "$((base_vm+1))" --net0 e1000,bridge=vmbr"$base_br" \
                                --net1 e1000,bridge=vmbr"$((base_br+1))" \
                                --net2 e1000,bridge=vmbr"$((base_br+2))"
        
        # SRV: только интерфейс к своему мосту (vmbrX+1)
        qm set "$((base_vm+2))" --net0 e1000,bridge=vmbr"$((base_br+1))"
        
        # CLI: только интерфейс к своему мосту (vmbrX+2)
        qm set "$((base_vm+3))" --net0 e1000,bridge=vmbr"$((base_br+2))"
    }

    # Создаем пользователя и настраиваем права
    if ! pveum user list | grep -q "user$base_vm@pve"; then
        pveum user add "user$base_vm@pve" --password "P@ssw0rd"
    fi
    
    if ! pveum pool list | grep -q "pool$base_vm"; then
        pveum pool add "pool$base_vm" --comment "Стенд пользователя $base_vm"
    fi
    
    pveum pool modify "pool$base_vm" --vms "$base_vm,$((base_vm+1)),$((base_vm+2)),$((base_vm+3))"

    pveum acl modify "/pool/pool$base_vm" --roles PVEVMUser --users "user$base_vm@pve"

    echo "Стенд $i развёрнут. Данные: user$base_vm / P@ssw0rd"
    echo -e "\033[32m Выполнено \033[0m"
}

delete_stand() {
    local stand_id=$1
    echo "Удаление стенда $stand_id"
    
    # Удаление виртуальных машин
    for vm_id in $(seq "$stand_id" "$((stand_id+3))"); do
        if qm status "$vm_id" 2>&1; then
            qm destroy "$vm_id" --destroy-unreferenced-disks 1 --purge 1
        fi
    done
    
    # Удаление сетевых интерфейсов
    for br in $(seq "$stand_id" "$((stand_id+nbr-1))"); do
        sed -i "/auto vmbr$br/,/bridge-fd 0/d" "/etc/network/interfaces"
        # Удаление пустых строк после конфигурации
        sed -i '/^$/N;/\n$/D' "/etc/network/interfaces"
    done
    
    # Удаление пользователя и пула
    if pveum user list | grep -q "user$stand_id@pve"; then
        pveum user delete "user$stand_id@pve"
    fi
    
    if pveum pool list | grep -q "pool$stand_id"; then
        pveum pool delete "pool$stand_id"
    fi
    
    echo "Стенд $stand_id удалён"
    echo -e "\033[32m Выполнено \033[0m"
}

delete_multiple_stands() {
    read -rp "Введите номера стендов (через пробел или диапазоном, например: 1010 1020 1030 или 1010-1030): " input

    # Разделим по пробелам
    for part in $input; do
        if [[ $part =~ ^[0-9]+-[0-9]+$ ]]; then
            # Диапазон
            IFS='-' read -r start end <<< "$part"
            for ((id=start; id<=end; id+=10)); do
                delete_stand "$id"
            done
        elif [[ $part =~ ^[0-9]+$ ]]; then
            # Одиночное число
            delete_stand "$part"
        else
            echo "Неверный формат: $part"
        fi
    done
}


# Меню и управление
show_main_menu() {
    echo "+=====================================================+"
    echo "| 1. Развернуть новые стенды                          |"
    echo "| 2. Удалить существующие стенды                      |"
    echo "| 3. Перезагрузить сетевые настройки                  |"
    echo "| 4. Выход                                            |"
    echo "+=====================================================+"
}

deploy_stands() {
    read -rp "VMID шаблона ISP: " ISP
    read -rp "VMID шаблона RTR: " RTR
    read -rp "VMID шаблона SRV: " SRV
    read -rp "VMID шаблона CLI: " CLI
    read -rp "Количество стендов: " USERS
    read -rp "Начальный VMID(1000, 2000, и т.д.): " START_ID

    for ((i = 1; i <= USERS; i++)); do
        configure_network "$i"
        deploy_user_stand "$i"
    done

    echo "Применение сетевых изменений..."
    systemctl restart networking
    sleep 4
}

delete_stand_menu() {
    read -rp "Базовый VMID стенда: " stand_id
    delete_stand "$stand_id"
}

# Главный цикл программы
while true; do
    show_main_menu
    read -rp "Выбор: " choice

    case $choice in
        1) deploy_stands ;;
        2) 
            echo "+=====================================================+"
            echo "| 1. Удалить один стенд                               |"
            echo "| 2. Удалить несколько стендов                        |"
            echo "+=====================================================+"
            read -rp "Выбор: " del_choice
            case $del_choice in
                1) delete_stand_menu ;;
                2) delete_multiple_stands ;;
                *) echo "Неверный выбор!" ;;
            esac
            ;;

        3) 
            systemctl restart networking
            echo "Сеть перезагружена!"
            sleep 1
            ;;
        4) exit 0 ;;
        *) 
            echo "Неверный выбор!"
            sleep 1 
            ;;
    esac
done