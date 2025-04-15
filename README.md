## A collection of scripts for Azure Front Door or Application Gateway with Azure Firewall or NVA

In this repo we go through the most two common architecture when it comes to hosting a web application behind Azure Application Gateway:
1. Azure Application Gateway before Azure Firewall (or NVA):
   * The traffic hits the application gateway, then routed to Azure Firewall (or NVA) for inspection before sending it to web application servers.
2. Azure Firewall (or NVA) beore Azure Application Gateway:
   * The traffic hits the Azure Firewall (or NVA), then the traffic will be sent to Azure Application Gateway which in turn will load balance the traffic to the backed web application servers.