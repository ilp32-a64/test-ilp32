/* module for the dlopen test: TLS reached through TLSDESC (general dynamic) */
__thread int tlsmod_var = 1234;

int tlsmod_get(void)
{
	return tlsmod_var;
}

int *tlsmod_addr(void)
{
	return &tlsmod_var;
}
