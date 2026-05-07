# Kr260 HW


ssh -t ubuntu@kr260u '
    echo "ubuntu ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/90-ubuntu-nopasswd > /dev/null
    sudo chmod 0440 /etc/sudoers.d/90-ubuntu-nopasswd
    sudo visudo -cf /etc/sudoers.d/90-ubuntu-nopasswd && echo OK || sudo rm -f /etc/sudoers.d/90-ubuntu-nopasswd
  '
