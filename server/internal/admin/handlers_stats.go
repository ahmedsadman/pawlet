package admin

import "net/http"

func (s *Server) notYet(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotImplemented, "not_implemented")
}
func (s *Server) overview(w http.ResponseWriter, r *http.Request)      { s.notYet(w, r) }
func (s *Server) installs(w http.ResponseWriter, r *http.Request)      { s.notYet(w, r) }
func (s *Server) installDetail(w http.ResponseWriter, r *http.Request) { s.notYet(w, r) }
func (s *Server) ban(w http.ResponseWriter, r *http.Request)           { s.notYet(w, r) }
func (s *Server) unban(w http.ResponseWriter, r *http.Request)         { s.notYet(w, r) }
func (s *Server) engagement(w http.ResponseWriter, r *http.Request)    { s.notYet(w, r) }
func (s *Server) reliability(w http.ResponseWriter, r *http.Request)   { s.notYet(w, r) }
func (s *Server) fleet(w http.ResponseWriter, r *http.Request)         { s.notYet(w, r) }
