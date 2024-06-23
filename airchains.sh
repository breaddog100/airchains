#!/bin/bash

# 检查Go环境
function check_go_installation() {
    if command -v go > /dev/null 2>&1; then
        echo "Go 环境已安装"
        return 0 
    else
        echo "Go 环境未安装，正在安装..."
        return 1 
    fi
}

# 节点安装功能
function install_node() {
    # 更新和安装必要的软件
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y curl jq build-essential git wget unzip

    # 安装 Go
    if ! check_go_installation; then
        sudo rm -rf /usr/local/go
        curl -L https://go.dev/dl/go1.22.0.linux-amd64.tar.gz | sudo tar -xzf - -C /usr/local
        echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> $HOME/.bash_profile
        source $HOME/.bash_profile
        go version
    fi

    # 克隆代码库
    cd $HOME
    git clone https://github.com/airchains-network/wasm-station.git
    git clone https://github.com/airchains-network/tracks.git

    # 设置Wasm Station
    cd wasm-station
    go mod tidy
    /bin/bash ./scripts/local-setup.sh
    
    # 启动
    sudo tee /etc/systemd/system/wasmstationd.service > /dev/null <<EOF 
[Unit]
Description=wasmstationd
After=network.target
[Service]
User=$USER
ExecStart=$HOME/wasm-station/build/wasmstationd start --api.enable
Restart=always
RestartSec=3
LimitNOFILE=10000
[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable wasmstationd
    sudo systemctl start wasmstationd
    
    # 安装eigenlayer cli
    cd $HOME
    wget https://github.com/airchains-network/tracks/releases/download/v0.0.2/eigenlayer
    sudo chmod +x eigenlayer
    sudo mv eigenlayer /usr/local/bin/eigenlayer
    
    # 设置Tracks
    sudo rm -rf ~/.tracks
    cd $HOME/tracks
    go mod tidy
    
    echo '====================== 安装完成 ==========================='
    
}

# 创建钱包
function add_wallet() {
	read -p "钱包名称: " wallet_name
    eigenlayer operator keys create  -i=true --key-type ecdsa $wallet_name
    
    echo "上面的信息记录好了吗。[Y/N]"
    read -r -p "请确认: " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            echo "很好"
            ;;
        *)
            echo "快复制下来"
            ;;
    esac

}

# 启动节点
function start_node(){
    source $HOME/.bash_profile
    read -p "节点名称: " node_name
    read -p "钱包公钥: " Public_Key_hex
    read -p "air地址名: " airchains_addr_name
    cd $HOME/tracks
    # 初始化sequencer
    go run cmd/main.go init --daRpc "disperser-holesky.eigenda.xyz" --daKey "$Public_Key_hex" --daType "eigen" --moniker "$node_name" --stationRpc "http://127.0.0.1:26657" --stationAPI "http://127.0.0.1:1317" --stationType "wasm"
    
    # 创建airchains 地址
    echo "保存好助记词和地址，后续会用到："
    #go run cmd/main.go keys junction --accountName $airchains_addr_name --accountPath $HOME/.tracks/junction-accounts/keys
    output=$(go run cmd/main.go keys junction --accountName $airchains_addr_name --accountPath $HOME/.tracks/junction-accounts/keys 2>&1)
    echo "$output"
    address=$(echo "$output" | grep 'Address:' | awk '{print $2}')
    
    # 初始化prover
    init_prover $airchains_addr_name $address
}

# 初始化prover
function init_prover(){
    source $HOME/.bash_profile
    go run cmd/main.go prover v1WASM
    nodeid=$(grep "node_id" ~/.tracks/config/sequencer.toml | awk -F '"' '{print $2}')
    ip=$(curl -s4 ifconfig.me/ip)
    bootstrapNode=/ip4/$ip/tcp/2300/p2p/$nodeid
    echo $bootstrapNode
    
    # 创建station
    go run cmd/main.go create-station --accountName $airchains_addr_name --accountPath $HOME/.tracks/junction-accounts/keys --jsonRPC "https://junction-testnet-rpc.synergynodes.com/" --info "WASM Track" --tracks $address --bootstrapNode "$bootstrapNode"
    
    # 修改gas price
    sed -i 's/gasFees := fmt.Sprintf("%damf", gas)/gasFees := fmt.Sprintf("%damf", 2*gas)/' "$HOME/tracks/junction/verifyPod.go"
    sed -i 's/gasFees := fmt.Sprintf("%damf", gas)/gasFees := fmt.Sprintf("%damf", 2*gas)/' "$HOME/tracks/junction/validateVRF.go"
    sed -i 's/gasFees := fmt.Sprintf("%damf", gas)/gasFees := fmt.Sprintf("%damf", 3*gas)/' "$HOME/tracks/junction/submitPod.go"

    # 启动station
    sudo tee /etc/systemd/system/stationd.service > /dev/null << EOF
[Unit]
Description=station track service
After=network-online.target
[Service]
User=$USER
WorkingDirectory=$HOME/tracks/
ExecStart=$(which go) run cmd/main.go start
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable stationd
    sudo systemctl start stationd

}

# 查看station日志
function view_stationd_logs() {
    sudo journalctl -u stationd -f -o cat
}

# 刷交易量tx
function tx_bot(){
    screen -S wasmstation -d -m bash -c "cd $HOME; addr=\$(\$HOME/wasm-station/build/wasmstationd keys show node --keyring-backend test -a); while true; do \$HOME/wasm-station/build/wasmstationd tx bank send node \$addr 1stake --from node --chain-id station-1 --keyring-backend test -y; sleep 6; done"
}

# 卸载节点功能
function uninstall_node() {
    echo "确定要卸载节点程序吗？这将会删除所有相关的数据。[Y/N]"
    read -r -p "请确认: " response

    case "$response" in
        [yY][eE][sS]|[yY]) 
            echo "开始卸载节点程序..."
            sudo systemctl stop stationd
            sudo systemctl stop wasmstationd
            rm -rf $HOME/wasm-station $HOME/tracks $HOME/.tracks $HOME/.wasmstationd 
            echo "节点程序卸载完成。"
            ;;
        *)
            echo "取消卸载操作。"
            ;;
    esac
}

# 主菜单
function main_menu() {
    while true; do
        clear
        echo "===============Airchains 一键部署脚本==============="
    	echo "沟通电报群：https://t.me/lumaogogogo"
    	echo "最低配置：2C4G100G；推荐配置：4C8G300G"
        echo "请选择项"
        echo "1. 安装节点 install_node"
        echo "2. 创建钱包 add_wallet"
        echo "3. 启动节点 start_node"
        echo "4. 查看日志 view_stationd_logs"
        echo "5. 交易机器人 tx_bot"
        echo "1618. 卸载节点 uninstall_node"
        echo "0. 退出脚本exit"
        read -p "请输入选项（1-10）: " OPTION

        case $OPTION in
        1) install_node ;;
        2) add_wallet ;;
        3) start_node ;;
        4) view_stationd_logs ;;
        5) tx_bot ;;
        1618) uninstall_node ;;
        0) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项。" ;;
        esac
        echo "按任意键返回主菜单..."
        read -n 1
    done
    
}

# 显示主菜单
main_menu