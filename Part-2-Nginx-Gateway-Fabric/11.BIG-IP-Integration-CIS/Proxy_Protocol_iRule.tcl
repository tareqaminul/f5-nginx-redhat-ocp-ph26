# /Common/Proxy_Protocol_iRule
# Prepends a PROXY protocol v1 header so NGINX sees the real client address.
# Verified on BIG-IP 17.5.1.3.
when CLIENT_ACCEPTED {
    set client_ip [IP::client_addr]
    set proxy_ver [expr {[string match "*:*" $client_ip] ? "TCP6" : "TCP4"}]
    set proxy_hdr "PROXY $proxy_ver $client_ip [IP::local_addr] [TCP::client_port] [TCP::local_port]\r\n"
}
when SERVER_CONNECTED {
    TCP::respond $proxy_hdr
}
