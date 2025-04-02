#!/bin/bash
LOG_FILE="/var/log/setup_script.log"
exec > >(tee -a "$LOG_FILE") 2>&1


sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh
# إنشاء ملف authorized_keys مع الصلاحيات الصحيحة
sudo touch /root/.ssh/authorized_keys
sudo chmod 600 /root/.ssh/authorized_keys
# طلب مفتاح SSH من المستخدم وإضافته إلى authorized_keys
# تعطيل تسجيل الدخول بالروت
# echo "Disabling root login..."
# sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
# تعطيل تسجيل الدخول بكلمة المرور
echo "Disabling password authentication..."
sudo sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
# إعادة تشغيل SSH لتطبيق التغييرات
echo "Restarting SSH service..."
sudo systemctl restart ssh
echo "Setup complete. Root login and password authentication are disabled."


add_root_key() {
    echo "🔑 Paste the SSH Public Key to add for root:"
    read -r SSH_KEY

    if [[ $SSH_KEY == ssh-* ]]; then
        echo "$SSH_KEY" | sudo tee -a /root/.ssh/authorized_keys > /dev/null
        echo "✅ SSH key added successfully!"
    else
        echo "❌ Invalid SSH key format!"
    fi
}

clear_root_keys() {
    echo "⚠️ Are you sure you want to delete ALL root SSH keys? [y/N]"
    read -r confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        sudo truncate -s 0 /root/.ssh/authorized_keys
        echo "🗑️ All keys removed from /root/.ssh/authorized_keys."
    else
        echo "❎ Operation canceled."
    fi
}

remove_root_key() {
    echo "🔍 Enter a keyword (email, comment, or part of the key) to match and delete:"
    read -r keyword

    if sudo grep -q "$keyword" /root/.ssh/authorized_keys; then
        echo "⚠️ Found matching key. Do you want to delete it? [y/N]"
        read -r confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            sudo sed -i "/$keyword/d" /root/.ssh/authorized_keys
            echo "🧽 Key(s) containing '$keyword' removed."
        else
            echo "❎ Deletion canceled."
        fi
    else
        echo "🔎 No matching key found for '$keyword'."
    fi
}



read -p "Do you want to add Key (yes/no): " ADD_KEY
if [[ "$ADD_KEY" == "yes" ]]; then
    add_root_key
fi

read -p "Do you want to remove Key (yes/no): " REMOVE_KEY
if [[ "$REMOVE_KEY" == "yes" ]]; then
    remove_root_key
fi

read -p "DO YOU WANT TO CLEAR ALL KEYS (yes/no): " CLEAR_KEYS
if [[ "$CLEAR_KEYS" == "yes" ]]; then
    clear_root_keys
fi